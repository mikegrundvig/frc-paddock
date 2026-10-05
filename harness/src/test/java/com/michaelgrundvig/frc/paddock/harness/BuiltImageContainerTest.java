package com.michaelgrundvig.frc.paddock.harness;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.List;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.junit.jupiter.api.io.TempDir;
import org.testcontainers.containers.BindMode;
import org.testcontainers.containers.Container;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.SelinuxContext;
import org.testcontainers.images.builder.Transferable;
import org.testcontainers.utility.DockerImageName;
import org.testcontainers.utility.MountableFile;

/**
 * A drive's image built by local-build.sh from a base like a board's (a boot partition, then the
 * root), read partition by partition: grown, its steps run (one leaving a process behind), its root
 * read-only, the data partition added, the computer stamped and released. It needs a rootful
 * runtime's loop devices: it skips under rootless Podman, and must run in CI.
 */
@ContainerTest
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class BuiltImageContainerTest {
  static final String REPOSITORY = "team/robot-images";

  @TempDir static Path work;
  GenericContainer<?> builder;

  @BeforeAll
  void build() throws IOException {
    if (!ContainerRuntime.rootful()) {
      if (Boolean.getBoolean("paddock.requireContainers")) {
        throw new IllegalStateException("CI must build an image, and its runtime is rootless");
      }
      assumeTrue(false, "building an image needs a rootful runtime's loop devices");
    }
    Path yq = Path.of(Host.run(List.of("bash", "-c", "command -v yq")).strip());
    ContainerRuntime.removeLeftovers();
    builder =
        new GenericContainer<>(DockerImageName.parse(Images.builder(Host.engine(), yq)))
            .withLabel(ContainerRuntime.LABEL, ContainerRuntime.OWNER)
            .withPrivilegedMode(true)
            // This machine's /dev as it is (no SELinux labels, which can't be put on it): the loop
            // devices' partitions appear in it as they're attached.
            .withCreateContainerCmdModifier(
                cmd -> cmd.getHostConfig().withSecurityOpts(List.of("label=disable")))
            .withCommand("sleep", "infinity");
    builder.addFileSystemBind("/dev", "/dev", BindMode.READ_WRITE, SelinuxContext.NONE);
    builder.start();
    builder.copyFileToContainer(MountableFile.forHostPath(team(work.resolve("team"))), "/team");
    String script;
    try (InputStream in = getClass().getResourceAsStream("build-a-drive.sh")) {
      script = new String(in.readAllBytes(), StandardCharsets.UTF_8);
    }
    builder.copyFileToContainer(Transferable.of(script, 0755), "/build-a-drive.sh");
    Container.ExecResult result = exec("/build-a-drive.sh");
    assertThat(result.getExitCode())
        .as("the build:\n%s%s", result.getStdout(), result.getStderr())
        .isZero();
  }

  @AfterAll
  void stop() {
    if (builder != null) {
      builder.close();
    }
  }

  @Test
  void theReleaseChecksOut() {
    assertThat(run("sh", "-c", "cd /out/release && sha256sum --check --strict SHA256SUMS"))
        .contains("vision-front-images-test.img.xz: OK");
    assertThat(run("yq", "-p", "json", ".computers[0].hostname", "/out/release/manifest.json"))
        .isEqualToIgnoringWhitespace("vision-front");
  }

  @Test
  void theDriveIsTheBasesPartitionsThenTheData() {
    assertThat(run("sh", "-c", "ls /out/p*.fs"))
        .isEqualToIgnoringWhitespace("/out/p1.fs /out/p2.fs /out/p3.fs");
    assertThat(label(1)).isEqualTo("boot");
    assertThat(label(2)).isEqualTo("rootfs");
    assertThat(label(3)).isEqualTo("paddock-data");
    for (int n = 1; n <= 3; n++) {
      assertThat(exec("e2fsck", "-fn", "/out/p" + n + ".fs").getExitCode())
          .as("partition %d's filesystem check", n)
          .isZero();
    }
  }

  @Test
  void theRootIsGrownToFillItsPartition() {
    // 1 GiB of base, its root from sector 67584, then grow: 256M.
    long partition = (2097152L - 67584 + 256 * 2048) * 512;
    assertThat(Long.parseLong(run("stat", "-c", "%s", "/out/p2.fs").strip())).isEqualTo(partition);
    String header = run("dumpe2fs", "-h", "/out/p2.fs");
    long blocks = Long.parseLong(field(header, "Block count"));
    long size = Long.parseLong(field(header, "Block size"));
    assertThat(blocks * size).isEqualTo(partition);
  }

  @Test
  void aStepWritesToTheBootPartitionWhereTheFstabMountsIt() {
    assertThat(read(1, "/config.txt")).isEqualTo("dtparam=example=on");
  }

  @Test
  void theStepsRanInTheChroot() {
    assertThat(read(2, "/etc/team/marker")).isEqualTo("built as vision");
    assertThat(read(2, "/usr/bin/example-tool")).contains("echo example");
    // A dependency apt downloaded inside the image, as its own unprivileged user.
    assertThat(debugfs(2, "stat /usr/bin/jq")).contains("Type: regular");
    // Debian's container images have a policy-rc.d of their own: the build puts it back.
    assertThat(read(2, "/usr/sbin/policy-rc.d")).contains("For most Docker users");
    assertThat(debugfs(2, "stat /usr/sbin/policy-rc.d.paddock-saved")).contains("File not found");
  }

  @Test
  void whatTheStepsLeftRunningIsStoppedAndNothingStaysAttached() {
    assertThat(exec("pgrep", "-f", "sleep 600").getExitCode()).as("pgrep's exit").isEqualTo(1);
    assertThat(
            run(
                "sh",
                "-c",
                "losetup --associated /out/vision.img; losetup --associated /out/drive.img"))
        .isBlank();
  }

  @Test
  void theRootIsReadOnlyWithTheKeptPathsOnTheData() {
    String fstab = read(2, "/etc/fstab");
    assertThat(fstab)
        .contains("LABEL=rootfs / ext4 ro,noatime 0 1")
        .contains("PARTUUID=0b1c2d3e-01 /boot/firmware ext4 defaults 0 2")
        .contains("LABEL=paddock-data /data ext4");
    assertThat(debugfs(2, "ls /var/lib/team")).doesNotContain("state");
    assertThat(read(3, "/var/lib/team/state")).isEqualTo("what the base had");
  }

  @Test
  void theComputerIsStamped() {
    assertThat(read(2, "/etc/hostname")).isEqualTo("vision-front");
    assertThat(read(2, "/etc/machine-id")).isEqualTo(Host.machineId(REPOSITORY, "vision-front"));
    String profile = "/etc/NetworkManager/system-connections/paddock.nmconnection";
    assertThat(read(2, profile)).contains("address1=10.99.71.11/24,10.99.71.4");
    assertThat(debugfs(2, "stat " + profile)).contains("Mode:  0600");
    assertThat(read(2, "/usr/lib/os-release")).contains("IMAGE_VERSION=\"images-test\"");
    assertThat(read(2, "/etc/team/camera.yaml")).isEqualTo("fx: 600.0");
  }

  /** The team's repository: its input, a file for the boot partition, a script, a package. */
  static Path team(Path repo) throws IOException {
    Host.write(
        repo.resolve("paddock.yaml"),
        """
        images:
          vision:
            from:
              url: https://example.org/images/base.img.gz
              sha256: %s
              arch: amd64
            grow: 256M
            steps:
              - file: config/config.txt
                to: /boot/firmware/config.txt
              - package: https://example.org/releases/example-tool_1.0.0_all.deb
                sha256: %s
              - run: setup/mark.sh
            read-only:
              data: 64M
              keep: [/var/lib/team]
        computers:
          - hostname: vision-front
            image: vision
            address: 10.99.71.11/24
            gateway: 10.99.71.4
            files:
              - file: computers/vision-front/camera.yaml
                to: /etc/team/camera.yaml
        """
            .formatted("a".repeat(64), "1".repeat(64)));
    Host.write(repo.resolve("config/config.txt"), "dtparam=example=on\n");
    Host.write(repo.resolve("computers/vision-front/camera.yaml"), "fx: 600.0\n");
    // A script that leaves a process running, as a package's daemon might: the build stops it.
    Path script = repo.resolve("setup/mark.sh");
    Host.write(
        script,
        """
        #!/bin/sh
        mkdir -p /etc/team
        echo "built as $PADDOCK_IMAGE" >/etc/team/marker
        setsid sleep 600 >/dev/null 2>&1 &
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

  /** A file's text in partition N. */
  String read(int n, String path) {
    return run("debugfs", "-R", "cat " + path, "/out/p" + n + ".fs").strip();
  }

  /** What debugfs says to a request on partition N, its errors and banner included. */
  String debugfs(int n, String request) {
    return run("sh", "-c", "debugfs -R \"$1\" \"$2\" 2>&1", "_", request, "/out/p" + n + ".fs");
  }

  String label(int n) {
    return run("blkid", "-p", "-o", "value", "-s", "LABEL", "/out/p" + n + ".fs").strip();
  }

  static String field(String header, String name) {
    return header
        .lines()
        .filter(line -> line.startsWith(name + ":"))
        .findFirst()
        .orElseThrow(() -> new IllegalStateException("no " + name + " in:\n" + header))
        .substring(name.length() + 1)
        .strip();
  }

  /** Runs a command in the builder, and answers what it printed; fails if it fails. */
  String run(String... command) {
    Container.ExecResult result = exec(command);
    if (result.getExitCode() != 0) {
      throw new IllegalStateException(
          String.join(" ", command) + " failed: " + result.getStderr() + result.getStdout());
    }
    return result.getStdout();
  }

  Container.ExecResult exec(String... command) {
    try {
      return builder.execInContainer(command);
    } catch (IOException e) {
      throw new IllegalStateException(e);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException(e);
    }
  }
}
