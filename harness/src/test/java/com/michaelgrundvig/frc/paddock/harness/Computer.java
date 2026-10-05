package com.michaelgrundvig.frc.paddock.harness;

import com.github.dockerjava.api.model.Capability;
import com.github.dockerjava.api.model.HostConfig;
import java.io.IOException;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import org.testcontainers.containers.Container;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.utility.DockerImageName;

/**
 * A computer in a container: systemd as its first process, so units and their failures are real.
 * {@link #start} returns once systemd has booted it. Rootless Podman needs SYS_ADMIN (for systemd's
 * sandboxing) and NET_ADMIN (for NetworkManager); Docker needs privileged mode.
 */
final class Computer extends GenericContainer<Computer> {
  /** What systemd needs in RAM, as on a board. */
  static final Map<String, String> TMPFS =
      Map.of("/run", "rw,exec,mode=755", "/run/lock", "rw", "/tmp", "rw,exec,mode=1777");

  /**
   * @param image the image, from {@link Images}
   * @param hostname its hostname
   */
  Computer(String image, String hostname) {
    super(DockerImageName.parse(image));
    boolean podman = ContainerRuntime.podman();
    withLabel(ContainerRuntime.LABEL, ContainerRuntime.OWNER);
    withTmpFs(TMPFS);
    withCreateContainerCmdModifier(
        cmd -> {
          cmd.withHostName(hostname);
          HostConfig host = cmd.getHostConfig();
          if (host == null) {
            return;
          }
          if (podman) {
            host.withCapAdd(Capability.SYS_ADMIN, Capability.NET_ADMIN)
                .withSecurityOpts(List.of("label=disable"));
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

  /** Its root read-only, as a read-only image's is on its drive. */
  Computer withReadOnlyRoot() {
    return withCreateContainerCmdModifier(
        cmd -> {
          if (cmd.getHostConfig() != null) {
            cmd.getHostConfig().withReadonlyRootfs(true);
          }
        });
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
}
