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
    directory = ./.;
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
  obsidianRoute = config.services.caddy.virtualHosts."fixture--app-obsidian".extraConfig;
  vaultwardenRoute =
    lib.replaceStrings [ context.privateIngress.destinationIPv4 ] [ privateIP ]
      config.services.caddy.virtualHosts."fixture--app-vaultwarden".extraConfig;
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
    ];
  }
  ''
    set -euxo pipefail
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
      curl --noproxy '*' --silent --show-error \
        --resolve "$host:${toString port}:$listener" \
        "http://$host:${toString port}$path"
    }
    status() {
      local host="$1" listener="$2" path="$3"
      curl --noproxy '*' --silent --show-error --output /dev/null --write-out '%{http_code}' \
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
    curl --noproxy '*' --silent --show-error --head \
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

    printf '%s\n' \
      'Obsidian allowed paths = 200 with backend body' \
      'Obsidian blocked paths = 404' \
      'Vaultwarden public admin paths = 404' \
      'Vaultwarden private admin paths = 200 with backend body' \
      'Vaultwarden private root = redirect to /admin' \
      'Vaultwarden public normal routes = backend body' \
      'Vaultwarden private general/static routes = backend body' \
      'Vaultwarden /vault and /vault/* = 404 on both listeners' > "$out/result.txt"
  ''
