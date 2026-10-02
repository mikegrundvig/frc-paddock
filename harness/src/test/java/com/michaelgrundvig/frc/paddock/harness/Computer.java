package com.michaelgrundvig.frc.paddock.harness;

import com.github.dockerjava.api.model.Capability;
import com.github.dockerjava.api.model.HostConfig;
import java.io.IOException;
import java.net.URI;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import org.testcontainers.containers.Container;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.utility.DockerImageName;

/**
 * A coprocessor in a container, as close to a board as a container gets: systemd as its first
 * process, so units, their ordering, and their failures are real; its root read-only, with {@code
 * /data} a writable volume and the rest that's written in RAM, as on a board's image; with its
 * hostname. It's started once systemd has finished booting it. Rootless Podman runs it as is, given
 * SYS_ADMIN (its user namespace's, for systemd's sandboxing) and no SELinux labels; Docker needs
 * privileged mode.
 */
final class Computer extends GenericContainer<Computer> {
  /** PhotonVision's port: its page and its API. */
  static final int PHOTONVISION = 5800;

  /**
   * What's written while it runs, in RAM, as on a board's image (its fstab's tmpfs, and systemd's
   * /run). Where a board lets programs run from them, so does this: Docker's tmpfs is noexec unless
   * told otherwise.
   */
  static final Map<String, String> TMPFS =
      Map.of(
          "/run", "rw,exec,mode=755",
          "/run/lock", "rw",
          "/tmp", "rw,exec,mode=1777",
          "/var/tmp", "rw,exec,mode=1777",
          "/var/log", "rw,mode=755",
          "/var/lib/systemd", "rw,mode=755");

  /**
   * @param image the image, from {@link Images}
   * @param hostname its hostname
   */
  Computer(String image, String hostname) {
    super(DockerImageName.parse(image));
    boolean podman = ContainerRuntime.podman();
    withExposedPorts(PHOTONVISION);
    withLabel(ContainerRuntime.LABEL, "true");
    withTmpFs(TMPFS);
    withCreateContainerCmdModifier(
        cmd -> {
          cmd.withHostName(hostname);
          HostConfig host = cmd.getHostConfig();
          if (host == null) {
            return;
          }
          host.withReadonlyRootfs(true);
          if (podman) {
            host.withCapAdd(Capability.SYS_ADMIN).withSecurityOpts(List.of("label=disable"));
          } else {
            host.withPrivileged(true);
          }
        });
    // Started once systemd has booted it: every unit started, or failed.
    waitingFor(
        Wait.forSuccessfulCommand(
                "state=$(systemctl is-system-running --wait 2>/dev/null);"
                    + " [ \"$state\" = running ] || [ \"$state\" = degraded ]")
            .withStartupTimeout(Duration.ofMinutes(2)));
  }

  /** A page of PhotonVision's, as the robot or a laptop reaches it. */
  URI photonVision(String path) {
    return URI.create("http://" + getHost() + ":" + getMappedPort(PHOTONVISION) + path);
  }

  /** Runs a command as root inside, and answers what it printed; fails if it fails. */
  String run(String... command) {
    Container.ExecResult result = exec(command);
    if (result.getExitCode() != 0) {
      throw new IllegalStateException(
          String.join(" ", command)
              + " failed ("
              + result.getExitCode()
              + "): "
              + result.getStderr()
              + result.getStdout());
    }
    return result.getStdout();
  }

  /** Runs a command as root inside, and answers how it went. */
  Container.ExecResult exec(String... command) {
    try {
      return execInContainer(command);
    } catch (IOException e) {
      throw new IllegalStateException(e);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException(e);
    }
  }

  /** PhotonVision's unit and its journal's last lines: why it isn't answering. */
  String photonVisionStatus() {
    return exec(
            "sh",
            "-c",
            "systemctl status photonvision --no-pager -n 0;"
                + " journalctl -u photonvision --no-pager -n 60 || true")
        .getStdout();
  }

  /** How much memory it uses now and has at most, its cgroup's, in MiB. */
  long[] memoryMb() {
    String current = run("cat", "/sys/fs/cgroup/memory.current").strip();
    String peak = run("sh", "-c", "cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo 0").strip();
    return new long[] {Long.parseLong(current) >> 20, Long.parseLong(peak) >> 20};
  }
}
