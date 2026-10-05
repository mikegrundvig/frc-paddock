package com.michaelgrundvig.frc.paddock.harness;

import com.github.dockerjava.api.DockerClient;
import com.github.dockerjava.api.model.Container;
import com.github.dockerjava.api.model.Info;
import com.github.dockerjava.api.model.VersionComponent;
import java.util.List;
import java.util.Locale;
import org.junit.jupiter.api.extension.ConditionEvaluationResult;
import org.junit.jupiter.api.extension.ExecutionCondition;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.testcontainers.DockerClientFactory;

/**
 * Whether the container tests can run here, and what they need to know of the runtime. Without one
 * they skip, or fail where the build requires them ({@code paddock.requireContainers}, in CI).
 */
final class ContainerRuntime implements ExecutionCondition {
  /**
   * The label every container a test starts carries: the process that started it, so a crashed
   * run's containers are found and removed while another run's are left alone.
   */
  static final String LABEL = "paddock.test.owner";

  /** This test run's process, the {@link #LABEL} of the containers it starts. */
  static final String OWNER = String.valueOf(ProcessHandle.current().pid());

  @Override
  public ConditionEvaluationResult evaluateExecutionCondition(ExtensionContext context) {
    String why = unavailable();
    if (why.isEmpty()) {
      return ConditionEvaluationResult.enabled("a container runtime runs Linux containers here");
    }
    if (Boolean.getBoolean("paddock.requireContainers")) {
      throw new IllegalStateException("Container tests must run in CI on Linux, and can't: " + why);
    }
    return ConditionEvaluationResult.disabled("No container runtime for Linux containers: " + why);
  }

  /** Why containers can't run here; empty when they can. */
  static String unavailable() {
    try {
      if (!DockerClientFactory.instance().isDockerAvailable()) {
        return "neither Docker nor Podman answers";
      }
      Info info = DockerClientFactory.instance().getInfo();
      String os = String.valueOf(info.getOsType()).toLowerCase(Locale.ROOT);
      return os.equals("linux") ? "" : "it runs " + os + " containers";
    } catch (RuntimeException e) {
      return String.valueOf(e.getMessage());
    }
  }

  /** Whether the runtime is Podman: it runs systemd in a container without privileged mode. */
  static boolean podman() {
    List<VersionComponent> components =
        DockerClientFactory.instance().client().versionCmd().exec().getComponents();
    return components != null
        && components.stream().anyMatch(c -> String.valueOf(c.getName()).contains("Podman"));
  }

  /**
   * Whether the runtime runs as root, so a privileged container can use this machine's loop
   * devices: Docker as on GitHub's runners, not rootless Podman or rootless Docker.
   */
  static boolean rootful() {
    List<String> options = DockerClientFactory.instance().getInfo().getSecurityOptions();
    return options == null || options.stream().noneMatch(o -> o.contains("name=rootless"));
  }

  /**
   * Removes the containers a crashed run left (the tests run without Testcontainers' cleanup
   * container): those whose process is gone, by their label, never anything else.
   */
  static void removeLeftovers() {
    DockerClient client = DockerClientFactory.instance().client();
    for (Container container :
        client.listContainersCmd().withShowAll(true).withLabelFilter(List.of(LABEL)).exec()) {
      String owner = container.getLabels().get(LABEL);
      if (!OWNER.equals(owner) && !alive(owner)) {
        client.removeContainerCmd(container.getId()).withForce(true).withRemoveVolumes(true).exec();
      }
    }
  }

  private static boolean alive(String pid) {
    try {
      return ProcessHandle.of(Long.parseLong(pid)).isPresent();
    } catch (NumberFormatException e) {
      return false;
    }
  }
}
