import json

fixture.start()
fixture.wait_for_unit("multi-user.target")
fixture.succeed("systemctl start vaultwarden couchdb")
fixture.wait_until_succeeds("curl -fsS http://127.0.0.1:8222/alive >/dev/null", timeout=300)
fixture.wait_until_succeeds("curl -fsS -u fixture:disposable-fixture-password http://127.0.0.1:5984/_up >/dev/null", timeout=300)
fixture.succeed("curl -fsS -u fixture:disposable-fixture-password -X PUT http://127.0.0.1:5984/obsidian >/dev/null")
fixture.succeed("curl -fsS -u fixture:disposable-fixture-password -H 'Content-Type: application/json' -X PUT http://127.0.0.1:5984/obsidian/leaf -d '{\"type\":\"leaf\",\"data\":\"fixture bytes\"}' >/dev/null")


def command(app, name):
    return f"/etc/fixture-{app}-export/bin/{name}"


def root(app):
    return f"/var/lib/clanwright-app-exports/{app}"


def metadata(app):
    return json.loads(fixture.succeed(f"cat {root(app)}/current/export.json"))


for app, service in (("vaultwarden", "vaultwarden"), ("livesync", "couchdb")):
    with subtest(f"{app}: manual native capture and independently copied readers"):
        fixture.succeed(f"test ! -e {root(app)}/current")
        fixture.fail(f"systemctl is-enabled apps-export-{app}.service")
        fixture.succeed(f"systemctl start apps-export-{app}")
        fixture.succeed(f"systemctl is-active {service}")
        first = metadata(app)
        fixture.succeed(f"install -d -m 0700 {root(app)}/current/nested-reader")
        fixture.fail(f"{command(app, 'prepare-reader')} --max-age 86400 {root(app)}/current/nested-reader")
        fixture.succeed(f"test -z \"$(find {root(app)}/current/nested-reader -mindepth 1 -print -quit)\"; rmdir {root(app)}/current/nested-reader")
        fixture.succeed(f"install -d -m 0700 /tmp/{app}-reader-a /tmp/{app}-reader-b")
        for suffix in ("a", "b"):
            fixture.succeed(f"{command(app, 'prepare-reader')} --max-age 86400 /tmp/{app}-reader-{suffix}")
        # Readers remain live while the next native capture replaces publication.
        fixture.succeed(f"systemctl start apps-export-{app}")
        second = metadata(app)
        assert first["captureId"] != second["captureId"]
        for suffix in ("a", "b"):
            old = json.loads(fixture.succeed(f"cat /tmp/{app}-reader-{suffix}/export.json"))
            assert old == first
        fixture.succeed(f"touch /tmp/{app}-reader-a/reader-only; test ! -e /tmp/{app}-reader-b/reader-only; test ! -e {root(app)}/current/reader-only")

    with subtest(f"{app}: inactive application remains inactive"):
        fixture.succeed(f"systemctl stop {service}; systemctl start apps-export-{app}")
        fixture.fail(f"systemctl is-active {service}")
        fixture.succeed(f"systemctl start {service}")

    with subtest(f"{app}: two held native consumers do not block fresh publication"):
        shared = metadata(app)
        fixture.succeed("touch /run/fixture-hold-readers")
        for suffix in ("a", "b"):
            fixture.succeed(f"systemctl start --no-block restic-backups-{app}-{suffix}")
            fixture.wait_until_succeeds(f"test -e /run/fixture-reader-{app}-{suffix}-ready")
        fixture.succeed(f"systemctl start apps-export-{app}", timeout=600)
        assert metadata(app)["captureId"] != shared["captureId"]
        for suffix in ("a", "b"):
            copied = json.loads(fixture.succeed(f"cat /var/cache/restic-backups-{app}-{suffix}/apps-input/export.json"))
            assert copied == shared
        fixture.succeed("rm /run/fixture-hold-readers")
        for suffix in ("a", "b"):
            fixture.wait_until_succeeds(f"test \"$(systemctl show restic-backups-{app}-{suffix} -p ActiveState --value)\" = inactive", timeout=600)
            fixture.succeed(f"test \"$(systemctl show restic-backups-{app}-{suffix} -p Result --value)\" = success")

    if app == "vaultwarden":
        with subtest("Vaultwarden: two actively uploading rate-limited native Restic jobs"):
            # Restic 0.19.1 wraps its local backend in the standard limiter.
            # New incompressible bytes defeat compression and prior deduplication.
            fixture.succeed("dd if=/dev/urandom of=/var/lib/vaultwarden/fixture-upload-payload bs=1M count=2 status=none; systemctl start apps-export-vaultwarden")
            uploading = metadata(app)
            for suffix in ("a", "b"):
                fixture.succeed(f"systemctl start --no-block restic-backups-{app}-{suffix}")
            for suffix in ("a", "b"):
                # Local.Save creates a temporary pack file while its rate-limited
                # reader streams bytes. This observes actual backup data I/O.
                fixture.wait_until_succeeds(f"test -n \"$(find /var/lib/fixture-repositories/{app}-{suffix}/data -type f -name '*-tmp-*' -print -quit)\"", timeout=120)
            fixture.succeed("systemctl start apps-export-vaultwarden", timeout=180)
            assert metadata(app)["captureId"] != uploading["captureId"]
            fixture.succeed("systemctl is-active vaultwarden")
            for suffix in ("a", "b"):
                fixture.succeed(f"test -n \"$(find /var/lib/fixture-repositories/{app}-{suffix}/data -type f -name '*-tmp-*' -print -quit)\"")
                copied = json.loads(fixture.succeed(f"cat /var/cache/restic-backups-{app}-{suffix}/apps-input/export.json"))
                assert copied == uploading
            for suffix in ("a", "b"):
                fixture.wait_until_succeeds(f"test \"$(systemctl show restic-backups-{app}-{suffix} -p ActiveState --value)\" = inactive", timeout=300)
                fixture.succeed(f"test \"$(systemctl show restic-backups-{app}-{suffix} -p Result --value)\" = success")

    if app == "vaultwarden":
        with subtest("Vaultwarden: unavailable destination does not block peer or new capture"):
            before_failure = metadata(app)
            fixture.succeed("cp /run/backup-config/vaultwarden-a-repository /run/fixture-repository-saved; touch /run/fixture-not-a-directory; printf '/run/fixture-not-a-directory/repository\\n' > /run/backup-config/vaultwarden-a-repository")
            # Bound only this disposable failure scenario; the shipped example
            # keeps its normal two-hour consumer deadline.
            fixture.succeed("mkdir -p /run/systemd/system/restic-backups-vaultwarden-a.service.d; printf '[Service]\\nTimeoutStartSec=30s\\n' > /run/systemd/system/restic-backups-vaultwarden-a.service.d/fixture-timeout.conf; systemctl daemon-reload; systemctl start --no-block restic-backups-vaultwarden-a")
            fixture.wait_until_succeeds("journalctl -u restic-backups-vaultwarden-a --no-pager | grep -q 'fixture-not-a-directory/repository/config: not a directory'", timeout=20)
            fixture.succeed("test \"$(systemctl show restic-backups-vaultwarden-a -p ActiveState --value)\" = activating; systemctl start --no-block restic-backups-vaultwarden-b")
            fixture.succeed("systemctl start apps-export-vaultwarden; systemctl is-active vaultwarden")
            assert metadata(app)["captureId"] != before_failure["captureId"]
            fixture.succeed("test \"$(systemctl show restic-backups-vaultwarden-a -p ActiveState --value)\" = activating")
            fixture.wait_until_succeeds("test \"$(systemctl show restic-backups-vaultwarden-b -p ActiveState --value)\" = inactive", timeout=300)
            fixture.succeed("test \"$(systemctl show restic-backups-vaultwarden-b -p Result --value)\" = success; test ! -e /var/cache/restic-backups-vaultwarden-b/apps-input")
            fixture.wait_until_succeeds("test \"$(systemctl show restic-backups-vaultwarden-a -p ActiveState --value)\" = failed", timeout=60)
            fixture.succeed("test ! -e /var/cache/restic-backups-vaultwarden-a/apps-input; mv /run/fixture-repository-saved /run/backup-config/vaultwarden-a-repository; rm /run/fixture-not-a-directory /run/systemd/system/restic-backups-vaultwarden-a.service.d/fixture-timeout.conf; systemctl daemon-reload; systemctl reset-failed restic-backups-vaultwarden-a")

    with subtest(f"{app}: four actual native Restic jobs and retained validators"):
        for suffix in ("a", "b"):
            job = f"{app}-{suffix}"
            fixture.fail(f"systemctl is-enabled restic-backups-{job}.timer")
            captured_before_upload = metadata(app)
            fixture.succeed(f"systemctl start restic-backups-{job}")
            fixture.succeed(f"test ! -e /var/cache/restic-backups-{job}/apps-input")
            destination = f"/tmp/restore-{job}"
            fixture.succeed(f"RESTIC_PASSWORD_FILE=/run/backup-secrets/{job}-password restic -r /var/lib/fixture-repositories/{job} restore latest --target {destination}")
            restored = f"{destination}/var/cache/restic-backups-{job}/apps-input"
            restored_metadata = json.loads(fixture.succeed(f"cat {restored}/export.json"))
            assert restored_metadata == captured_before_upload
            assert metadata(app) == captured_before_upload
            fixture.succeed(f"{command(app, 'validate')} {restored}", timeout=900)

    with subtest(f"{app}: failed and interrupted actual captures preserve publication"):
        before = metadata(app)
        # The real capture acquires this compatibility lock before stopping its
        # application. A held lock provides a deterministic interruption point.
        lock = f"/run/lock/apps-{app}-recovery.lock"
        fixture.succeed(f"systemd-run --unit=fixture-lock-{app} flock {lock} /run/current-system/sw/bin/sleep 180")
        fixture.wait_until_succeeds(f"! flock -n {lock} true")
        fixture.succeed(f"systemctl start --no-block apps-export-{app}")
        fixture.wait_until_succeeds(f"test -d {root(app)}/pending")
        fixture.succeed(f"systemctl stop apps-export-{app}")
        fixture.succeed(f"systemctl stop fixture-lock-{app}")
        assert metadata(app) == before
        fixture.succeed(f"test ! -e {root(app)}/pending; systemctl is-active {service}")
        # Missing real application state causes the native handler to fail.
        source = "/var/lib/vaultwarden" if app == "vaultwarden" else fixture.succeed("cat /etc/fixture-couchdb-directory").strip()
        fixture.succeed(f"systemctl stop {service}; mv {source} {source}.fixture-saved")
        fixture.fail(f"systemctl start apps-export-{app}")
        assert metadata(app) == before
        fixture.succeed(f"mv {source}.fixture-saved {source}; systemctl reset-failed apps-export-{app}; systemctl start {service}")
        fixture.succeed(f"install -d -m 0700 /tmp/{app}-after-failure; {command(app, 'prepare-reader')} --max-age 86400 /tmp/{app}-after-failure")
        fixture.sleep(2)
        fixture.succeed(f"install -d -m 0700 /tmp/{app}-expired")
        fixture.fail(f"{command(app, 'prepare-reader')} --max-age 1 /tmp/{app}-expired")
        assert metadata(app) == before

with subtest("Vaultwarden: native pre/post failure and TERM after application pause"):
    before = metadata("vaultwarden")
    for stage in ("pre", "post"):
        fixture.succeed(f"touch /run/fixture-fail-{stage}")
        fixture.fail("systemctl start apps-export-vaultwarden")
        fixture.succeed("systemctl is-active vaultwarden; test ! -e /var/lib/clanwright-app-exports/vaultwarden/pending")
        assert metadata("vaultwarden") == before
        fixture.succeed(f"rm /run/fixture-fail-{stage}; systemctl reset-failed apps-export-vaultwarden")
    fixture.succeed("touch /run/fixture-block-pre; systemctl start --no-block apps-export-vaultwarden")
    fixture.wait_until_succeeds("test -e /run/fixture-pre-blocked")
    fixture.fail("systemctl is-active vaultwarden")
    fixture.succeed("systemctl stop apps-export-vaultwarden", timeout=240)
    fixture.succeed("systemctl is-active vaultwarden; test ! -e /var/lib/clanwright-app-exports/vaultwarden/pending")
    assert metadata("vaultwarden") == before
    fixture.succeed("rm /run/fixture-block-pre /run/fixture-pre-blocked")
