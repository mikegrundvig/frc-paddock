package com.michaelgrundvig.frc.paddock.harness;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.List;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.io.TempDir;

/**
 * A read-only image as the engine builds one ({@link Images#stamped}), booted under systemd on a
 * read-only root with its kept paths on /data: each step did its part, the computer is stamped, and
 * no unit fails. The drive's partitions are {@link BuiltImageContainerTest}'s.
 */
@ContainerTest
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class StampedImageContainerTest {
  static final String COMMIT = "0123456789abcdef0123456789abcdef01234567";
  static final String REPOSITORY = "team/robot-images";

  @TempDir static Path work;
  Path engine;
  Computer computer;

  @BeforeAll
  void build() throws IOException {
    Path repo = team(work.resolve("team"));
    Path plan = work.resolve("plan");
    engine = Host.engine();
    Host.run(
        List.of(
            "bash",
            engine.resolve("plan.sh").toString(),
            "--config",
            repo.resolve("paddock.yaml").toString(),
            "--out",
            plan.toString(),
            "--commit",
            COMMIT,
            "--built-at",
            "2027-01-10T18:30:00Z",
            "--repository",
            REPOSITORY));
    ContainerRuntime.removeLeftovers();
    computer =
        new Computer(Images.stamped(engine, plan, repo, "vision", "vision-front"), "vision-front")
            .withReadOnlyRoot();
    computer.start();
  }

  @AfterAll
  void stop() {
    if (computer != null) {
      computer.close();
    }
  }

  @Test
  void itBootsWithNoFailedUnit() {
    String failed =
        computer.run("systemctl", "list-units", "--failed", "--all", "--plain", "--no-legend");
    assertThat(failed).as("failed units").isBlank();
    assertThat(computer.exec("systemctl", "is-system-running").getStdout().strip())
        .isEqualTo("running");
  }

  @Test
  void itsRootIsReadOnly() {
    assertThat(computer.exec("touch", "/etc/written").getExitCode()).isNotZero();
  }

  @Test
  void keptPathsAreOnTheDataPartition() {
    assertThat(computer.run("cat", "/var/lib/team/state").strip()).isEqualTo("from the build");
    computer.run("sh", "-c", "echo written >/var/lib/team/new");
    assertThat(computer.run("cat", "/data/var/lib/team/new").strip()).isEqualTo("written");
  }

  @Test
  void theJournalIsKept() {
    // Podman mounts a tmpfs of its own at /var/log/journal for systemd, under /var/log's.
    assumeFalse(ContainerRuntime.podman(), "Podman mounts its own /var/log/journal");
    // journald keeps its files in a folder named by the machine ID, once /var/log/journal is there.
    assertThat(computer.run("ls", "/data/var/log/journal").strip()).isEqualTo(machineId());
  }

  @Test
  void ramPathsAreInRam() {
    for (String path : List.of("/var/log", "/var/lib/systemd", "/var/lib/NetworkManager")) {
      assertThat(computer.run("findmnt", "-n", "-o", "FSTYPE", path).strip())
          .as(path)
          .isEqualTo("tmpfs");
    }
  }

  @Test
  void thePackageIsInstalledWithWhatItDependsOn() {
    assertThat(computer.run("example-tool").strip()).isEqualTo("example");
    assertThat(computer.run("dpkg-query", "-W", "-f=${Status}", "jq"))
        .isEqualTo("install ok installed");
  }

  @Test
  void theScriptRanInTheImage() {
    assertThat(computer.run("cat", "/etc/team/marker").strip()).isEqualTo("built as vision");
  }

  @Test
  void theFileIsInPlaceWithItsMode() {
    assertThat(computer.run("stat", "-c", "%a %U", "/etc/tool/tool.yaml").strip())
        .isEqualTo("600 root");
  }

  @Test
  void theDownloadIsInPlaceWithItsMode() {
    assertThat(computer.run("cat", "/opt/team/model.bin").strip()).isEqualTo("a model");
    assertThat(computer.run("stat", "-c", "%a %U", "/opt/team/model.bin").strip())
        .isEqualTo("640 root");
  }

  @Test
  void itsIdentityAndLabelsAreStamped() {
    assertThat(computer.run("cat", "/etc/machine-id").strip()).isEqualTo(machineId());
    String osRelease = computer.run("cat", "/etc/os-release");
    assertThat(osRelease)
        .contains("IMAGE_ID=\"vision\"")
        .contains("IMAGE_VERSION=\"build-" + COMMIT.substring(0, 12) + "\"")
        .contains("PADDOCK_COMMIT=\"" + COMMIT + "\"");
  }

  @Test
  void itHasItsOwnFiles() {
    assertThat(computer.run("cat", "/etc/team/camera.yaml").strip()).isEqualTo("fx: 600.0");
    assertThat(computer.run("stat", "-c", "%a %U", "/etc/team/camera.yaml").strip())
        .isEqualTo("640 root");
  }

  @Test
  void networkManagerTakesTheAddress() {
    assertThat(computer.run("nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"))
        .contains("paddock:802-3-ethernet");
    assertThat(
            computer.run("nmcli", "-g", "ipv4.addresses", "connection", "show", "paddock").strip())
        .isEqualTo("10.99.71.11/24");
    assertThat(computer.run("nmcli", "-g", "ipv4.gateway", "connection", "show", "paddock").strip())
        .isEqualTo("10.99.71.4");
  }

  static String machineId() {
    return Host.machineId(REPOSITORY, "vision-front");
  }

  /** A team's repository: its input, a file, a script, and a package's source. */
  static Path team(Path repo) throws IOException {
    Host.write(
        repo.resolve("paddock.yaml"),
        """
        images:
          vision:
            from:
              url: https://example.org/images/base.img.xz
              sha256: %s
              arch: amd64
            steps:
              - file: config/tool.yaml
                to: /etc/tool/tool.yaml
                mode: "0600"
              - package: https://example.org/releases/example-tool_1.0.0_all.deb
                sha256: %s
              - run: setup/mark.sh
              - download: https://example.org/releases/model.bin
                sha256: %s
                to: /opt/team/model.bin
                mode: "0640"
            read-only:
              data: 64M
              keep: [/var/lib/team, /var/log/journal]
        computers:
          - hostname: vision-front
            image: vision
            address: 10.99.71.11/24
            gateway: 10.99.71.4
            files:
              - file: computers/vision-front/camera.yaml
                to: /etc/team/camera.yaml
                mode: "0640"
        """
            .formatted("a".repeat(64), "1".repeat(64), "2".repeat(64)));
    Host.write(repo.resolve("config/tool.yaml"), "checks: [example]\n");
    Host.write(repo.resolve("computers/vision-front/camera.yaml"), "fx: 600.0\n");
    Host.write(repo.resolve("download/model.bin"), "a model\n");
    Path script = repo.resolve("setup/mark.sh");
    Host.write(
        script,
        """
        #!/bin/sh
        mkdir -p /etc/team /var/lib/team
        echo "built as $PADDOCK_IMAGE" >/etc/team/marker
        echo "from the build" >/var/lib/team/state
        """);
    Files.setPosixFilePermissions(script, PosixFilePermissions.fromString("rwxr-xr-x"));
    Host.write(
        repo.resolve("package/DEBIAN/control"),
        """
        Package: example-tool
        Version: 1.0.0
        Architecture: all
        Depends: jq
        Maintainer: nobody <nobody@localhost>
        Description: a team's package, for the tests
        """);
    Path tool = repo.resolve("package/usr/bin/example-tool");
    Host.write(tool, "#!/bin/sh\necho example\n");
    Files.setPosixFilePermissions(tool, PosixFilePermissions.fromString("rwxr-xr-x"));
    return repo;
  }
}
