{
  self,
  clan-core,
  network,
  ...
}:
let
  inherit (clan-core.inputs.nixpkgs) lib;
  pkgs = clan-core.inputs.nixpkgs.legacyPackages.x86_64-linux;
  port = 18083;
  publicIP = "127.0.0.1";
  privateIP = "127.0.0.2";
  backendIP = "127.0.0.3";
  context = {
    publicIPv4 = "192.0.2.10";
    certificateEmail = "fixture@example.invalid";
    privateIngress = {
      destinationIPv4 = "100.64.0.10";
      trustedInterfaces = [ "tailscale0" ];
    };
  };
  clan = clan-core.lib.clan {
    self.inputs = {
      inherit network;
      apps = self;
      self.clan = clan.config;
    };
    specialArgs.clan-core = clan-core;
    directory = "${self.outPath}/checks";
    imports = [
      self.clanModules.default
      {
        clanwright.apps.machines.fixture = {
          installation = context;
          obsidian.domain = "obsidian.example.invalid";
          vaultwarden.domain = "vaultwarden.example.invalid";
        };
        machines.fixture = {
          nixpkgs.hostPlatform = "x86_64-linux";
          boot.isContainer = true;
          system.stateVersion = "26.11";
          security.acme.certs = {
            "obsidian.example.invalid".dnsProvider = "timewebcloud";
            "vaultwarden.example.invalid".dnsProvider = "timewebcloud";
          };
          sops.defaultSopsFile = builtins.toFile "apps-http-fixture-sops.yaml" "sops:\n  age: []\n";
          sops.age.keyFile = "/run/fixture/age-key";
        };
        inventory = {
          meta.name = "apps-http-runtime";
          machines.fixture = { };
        };
      }
    ];
  };
  config = clan.config.nixosConfigurations.fixture.config;
  obsidianRoute = config.services.caddy.virtualHosts."obsidian.example.invalid".extraConfig;
  vaultwardenRoute =
    lib.replaceStrings [ context.privateIngress.destinationIPv4 ] [ privateIP ]
      config.services.caddy.virtualHosts."vaultwarden.example.invalid".extraConfig;
  runtimeCaddyfile = pkgs.writeText "apps-http-runtime-local.Caddyfile" ''
    http://obsidian.example.invalid:${toString port} {
      bind ${publicIP}
      ${lib.replaceStrings [ "127.0.0.1:5984" ] [ "${backendIP}:5984" ] obsidianRoute}
    }
    http://vaultwarden.example.invalid:${toString port} {
      bind ${publicIP} ${privateIP}
      ${lib.replaceStrings [ "127.0.0.1:8222" ] [ "${backendIP}:8222" ] vaultwardenRoute}
    }
    :5984 {
      bind ${backendIP}
      respond "couch fixture" 200
    }
    :8222 {
      bind ${backendIP}
      @clientIp path /client-ip /identity/accounts/prelogin /admin/client-ip /vw_static/client-ip
      respond @clientIp "X-Real-IP={http.request.header.X-Real-IP};X-Forwarded-For={http.request.header.X-Forwarded-For}" 200
      respond "vault fixture" 200
    }
  '';
in
assert config.services.caddy.package.outPath == network.packages.x86_64-linux.caddy-custom.outPath;
pkgs.runCommand "clanwright-apps-http-runtime"
  {
    nativeBuildInputs = [
      network.packages.x86_64-linux.caddy-custom
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
      config.services.fail2ban.package
    ];
  }
  ''
    set -euxo pipefail
    started=$SECONDS
    mkdir -p "$out" "$TMPDIR/home"
    export HOME="$TMPDIR/home"
    caddy adapt --validate --config ${runtimeCaddyfile} --adapter caddyfile \
      > "$out/adapted.json" 2> "$out/adapt.log"
    caddy run --config ${runtimeCaddyfile} --adapter caddyfile \
      > "$out/caddy.stdout.log" 2> "$out/caddy.stderr.log" &
    caddy_pid="$!"
    cleanup() {
      status="$?"
      kill "$caddy_pid" 2>/dev/null || true
      wait "$caddy_pid" 2>/dev/null || true
      if [ "$status" -ne 0 ]; then
        cat "$out/adapt.log" "$out/caddy.stdout.log" "$out/caddy.stderr.log" >&2
      fi
      exit "$status"
    }
    trap cleanup EXIT

    request() {
      local host="$1" listener="$2" path="$3"
      curl --max-time 5 --noproxy '*' --silent --show-error \
        --resolve "$host:${toString port}:$listener" \
        "http://$host:${toString port}$path"
    }
    status() {
      local host="$1" listener="$2" path="$3"
      curl --max-time 5 --noproxy '*' --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --resolve "$host:${toString port}:$listener" \
        "http://$host:${toString port}$path"
    }
    for attempt in $(seq 1 50); do
      if [ "$(status obsidian.example.invalid ${publicIP} / 2>/dev/null || true)" = 200 ]; then break; fi
      sleep 0.1
    done

    for path in / /_session /obsidian /obsidian/nested; do
      [ "$(status obsidian.example.invalid ${publicIP} "$path")" = 200 ]
      [ "$(request obsidian.example.invalid ${publicIP} "$path")" = 'couch fixture' ]
    done
    for path in /_all_dbs /_utils /obsidian-other /other; do
      [ "$(status obsidian.example.invalid ${publicIP} "$path")" = 404 ]
    done

    for path in /admin /admin/ /admin/nested; do
      [ "$(status vaultwarden.example.invalid ${publicIP} "$path")" = 404 ]
      [ "$(status vaultwarden.example.invalid ${privateIP} "$path")" = 200 ]
      [ "$(request vaultwarden.example.invalid ${privateIP} "$path")" = 'vault fixture' ]
    done
    [ "$(status vaultwarden.example.invalid ${privateIP} /)" = 302 ]
    curl --max-time 5 --noproxy '*' --silent --show-error --head \
      --resolve "vaultwarden.example.invalid:${toString port}:${privateIP}" \
      "http://vaultwarden.example.invalid:${toString port}/" \
      | grep -i '^location: /admin' > /dev/null
    [ "$(status vaultwarden.example.invalid ${publicIP} /)" = 200 ]
    [ "$(request vaultwarden.example.invalid ${publicIP} /)" = 'vault fixture' ]
    [ "$(status vaultwarden.example.invalid ${publicIP} /identity/accounts/prelogin)" = 200 ]
    [ "$(status vaultwarden.example.invalid ${privateIP} /identity/accounts/prelogin)" = 200 ]
    [ "$(status vaultwarden.example.invalid ${privateIP} /other)" = 200 ]
    [ "$(status vaultwarden.example.invalid ${privateIP} /vw_static/app.js)" = 200 ]
    for path in /vault /vault/nested; do
      [ "$(status vaultwarden.example.invalid ${publicIP} "$path")" = 404 ]
      [ "$(status vaultwarden.example.invalid ${privateIP} "$path")" = 404 ]
    done

    # Every proxy branch replaces a spoofed IP header with the socket peer.
    for listener in ${publicIP} ${privateIP}; do
      for path in /client-ip /identity/accounts/prelogin; do
        curl --max-time 5 --noproxy '*' --silent --show-error \
          --header 'X-Real-IP: 192.0.2.99' --header 'X-Forwarded-For: 198.51.100.99' \
          --resolve "vaultwarden.example.invalid:${toString port}:$listener" \
          "http://vaultwarden.example.invalid:${toString port}$path" \
          | grep -Fx 'X-Real-IP=127.0.0.1;X-Forwarded-For=127.0.0.1'
      done
    done
    for path in /admin/client-ip /vw_static/client-ip; do
      curl --max-time 5 --noproxy '*' --silent --show-error \
        --header 'X-Real-IP: 192.0.2.99' --header 'X-Forwarded-For: 198.51.100.99' \
        --resolve "vaultwarden.example.invalid:${toString port}:${privateIP}" \
        "http://vaultwarden.example.invalid:${toString port}$path" \
        | grep -Fx 'X-Real-IP=127.0.0.1;X-Forwarded-For=127.0.0.1'
    done

    # Use the effective native jail filter and its stock includes unchanged.
    mkdir -p "$out/fail2ban/filter.d"
    cp ${config.services.fail2ban.package}/etc/fail2ban/filter.d/common.conf "$out/fail2ban/filter.d/"
    cp ${config.services.fail2ban.package}/etc/fail2ban/filter.d/vaultwarden.conf "$out/fail2ban/filter.d/"
    cp ${
      config.environment.etc."fail2ban/filter.d/vaultwarden-auth.conf".source
    } "$out/fail2ban/filter.d/vaultwarden-auth.conf"
    cat > "$out/vaultwarden-journal-fixture.log" <<'JOURNAL'
    Sep 30 12:00:00 fixture vaultwarden[123]: [][vaultwarden::api::identity][ERROR] Username or password is incorrect. Try again. IP: 192.0.2.5. Username: fixture@example.invalid.
    Sep 30 12:00:01 fixture vaultwarden[123]: [][vaultwarden::api::admin][ERROR] Invalid admin token. IP: 192.0.2.6.
    Sep 30 12:00:02 fixture vaultwarden[123]: [][vaultwarden::api::core::two_factor::authenticator][ERROR] Invalid TOTP code! Server time: 123456. IP: 2001:db8::7.
    Sep 30 12:00:03 fixture vaultwarden[123]: [][vaultwarden::api::identity][INFO] Login successful. IP: 192.0.2.8.
    Sep 30 12:00:04 fixture vaultwarden[123]: [][vaultwarden::api::identity][ERROR] Database connection interrupted. IP: 192.0.2.9.
    Sep 30 12:00:05 fixture vaultwarden[123]: [][vaultwarden::api::identity][INFO] Username or password is incorrect. Try again. IP: 192.0.2.10. Username: fixture@example.invalid.
    Sep 30 12:00:06 fixture caddy[124]: {"remote_ip":"192.0.2.11","uri":"/identity/connect/token","status":400}
    Sep 30 12:00:07 fixture caddy[124]: {"remote_ip":"192.0.2.12","uri":"/admin","status":429}
    JOURNAL
    fail2ban-regex --config "$out/fail2ban" --usedns no \
      --print-all-matched --print-all-missed "$out/vaultwarden-journal-fixture.log" \
      filter.d/vaultwarden-auth.conf > "$out/fail2ban-regex.txt" \
      || { cat "$out/fail2ban-regex.txt" >&2; exit 1; }
    cat "$out/fail2ban-regex.txt"
    grep -E 'Lines: 8 lines, 0 ignored, 3 matched, 5 missed' "$out/fail2ban-regex.txt"

    # File input auto-selects logtype=file. Native backend=systemd selects
    # journal; apply that upstream filter init option to the same fixture.
    fail2ban-regex --config "$out/fail2ban" --usedns no \
      --print-all-matched --print-all-missed "$out/vaultwarden-journal-fixture.log" \
      'filter.d/vaultwarden-auth.conf[logtype=journal]' > "$out/fail2ban-regex-journal-prefix.txt" \
      || { cat "$out/fail2ban-regex-journal-prefix.txt" >&2; exit 1; }
    cat "$out/fail2ban-regex-journal-prefix.txt"
    grep -E 'Lines: 8 lines, 0 ignored, 3 matched, 5 missed' "$out/fail2ban-regex-journal-prefix.txt"

    printf '%s\n' \
      'Obsidian allowed paths = 200 with backend body' \
      'Obsidian blocked paths = 404' \
      'Vaultwarden public admin paths = 404' \
      'Vaultwarden private admin paths = 200 with backend body' \
      'Vaultwarden private root = redirect to /admin' \
      'Vaultwarden public normal routes = backend body' \
      'Vaultwarden private general/static routes = backend body' \
      'Vaultwarden /vault and /vault/* = 404 on both listeners' \
      'Vaultwarden all proxy branches replace spoofed client headers with socket peer' \
      'Native stock Vaultwarden auth filter: 3 matched positives / 5 missed negatives' > "$out/result.txt"
    printf 'body_seconds=%s\n' "$((SECONDS - started))" > "$out/timing.txt"
  ''
