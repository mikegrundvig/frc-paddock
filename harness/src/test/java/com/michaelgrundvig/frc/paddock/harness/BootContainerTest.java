package com.michaelgrundvig.frc.paddock.harness;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;

/**
 * The smoke test: a computer set up as an image runs PhotonVision (the pinned build, {@code
 * harness/photonvision-x86.json}) boots under systemd with no unit failed, and PhotonVision
 * answers.
 */
@ContainerTest
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class BootContainerTest {
  Computer computer;
  double bootedSeconds;
  double answeredSeconds;

  final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();

  @BeforeAll
  void boot() throws InterruptedException {
    ContainerRuntime.removeLeftovers();
    computer = new Computer(PhotonVisionImages.photonVision(), "vision-front");
    long starting = System.nanoTime();
    computer.start();
    bootedSeconds = (System.nanoTime() - starting) / 1e9;
    for (int i = 0; i < 1800 && !answers(); i++) {
      Thread.sleep(100);
    }
    answeredSeconds = (System.nanoTime() - starting) / 1e9;
  }

  @AfterAll
  void stop() {
    if (computer != null) {
      computer.close();
    }
  }

  /** Whether PhotonVision's page answers now. */
  boolean answers() {
    try {
      return http.send(
                  HttpRequest.newBuilder(computer.photonVision("/api/status"))
                      .timeout(Duration.ofSeconds(2))
                      .build(),
                  HttpResponse.BodyHandlers.discarding())
              .statusCode()
          == 200;
    } catch (IOException e) {
      return false;
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      return false;
    }
  }

  @Test
  void photonVisionAnswers() {
    assertThat(answers())
        .as(
            () ->
                "PhotonVision's page answers within 3 minutes; its unit and journal:\n"
                    + computer.photonVisionStatus())
        .isTrue();
    System.out.printf(
        "Booted in %.1f s; PhotonVision answered %.1f s after its container started%n%s%n",
        bootedSeconds,
        answeredSeconds,
        computer.run(
            "sh",
            "-c",
            "systemctl show photonvision --property=MainPID --property=ActiveEnterTimestamp;"
                + " journalctl -u photonvision --no-pager -n 5"));
  }

  @Test
  void itBootsWithNoFailedUnit() {
    String state = computer.exec("systemctl", "is-system-running").getStdout().strip();
    String failed =
        computer.run("systemctl", "list-units", "--failed", "--all", "--plain", "--no-legend");
    assertThat(failed).as("failed units").isBlank();
    assertThat(state).isEqualTo("running");
    long[] memory = computer.memoryMb();
    System.out.printf(
        "Booted with no failed unit; memory: %d MiB now, %d MiB at most%n", memory[0], memory[1]);
  }
}
