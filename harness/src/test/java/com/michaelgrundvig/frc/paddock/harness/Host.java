package com.michaelgrundvig.frc.paddock.harness;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

/** This machine, outside the containers: its files, its commands, and the engine on it. */
final class Host {
  private Host() {}

  /** The engine's folder, which the build gives the tests. */
  static Path engine() {
    String root = System.getProperty("paddock.root");
    if (root == null) {
      throw new IllegalStateException(
          "paddock.root isn't set: run the container tests with Gradle");
    }
    return Path.of(root).resolve("engine");
  }

  /** The machine ID stamping gives a computer, by the engine's own derivation. */
  static String machineId(String repository, String hostname) {
    return run(List.of(
            "bash",
            "-c",
            ". \"$1\"; derived_hex \"paddock machine-id/$2/$3\"",
            "_",
            engine().resolve("lib/common.sh").toString(),
            repository,
            hostname))
        .strip();
  }

  static void write(Path file, String text) throws IOException {
    Files.createDirectories(file.getParent());
    Files.writeString(file, text, StandardCharsets.UTF_8);
  }

  /**
   * Runs a command and answers what it printed, failing with that if it fails. Not into a GitHub
   * Actions step's outputs, where plan.sh would otherwise write.
   */
  static String run(List<String> command) {
    ProcessBuilder builder = new ProcessBuilder(command).redirectErrorStream(true);
    builder.environment().remove("GITHUB_OUTPUT");
    try {
      Process process = builder.start();
      String output;
      try (var in = process.getInputStream()) {
        output = new String(in.readAllBytes(), StandardCharsets.UTF_8);
      }
      if (process.waitFor() != 0) {
        throw new IllegalStateException(String.join(" ", command) + " failed:\n" + output);
      }
      return output;
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException(e);
    }
  }
}
