package com.michaelgrundvig.frc.paddock.tools;

import com.michaelgrundvig.frc.paddock.json.Json;
import com.michaelgrundvig.frc.paddock.json.JsonValue;
import com.michaelgrundvig.frc.paddock.settings.Settings;
import com.michaelgrundvig.frc.paddock.settings.SettingsFiles;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.TreeMap;
import java.util.stream.Stream;

/**
 * Paddock's build tasks, for a robot's build, with Paddock's own code, so they check exactly what
 * the images do:
 *
 * <ul>
 *   <li>{@code check-lock <lock> [<vendordep>]}: checks PhotonVision's lock (every address and
 *       checksum, or a placeholder), against PhotonLib's vendordep when given, and names the
 *       placeholders still in it;
 *   <li>{@code settings-hashes <settings> <out.json>}: each computer's committed settings hash, by
 *       name, from the team's settings folder (one folder per computer; an empty one is none).
 * </ul>
 *
 * <p>A failure prints what's wrong and exits with status 1.
 */
public final class PaddockBuild {
  private PaddockBuild() {}

  /** Runs one task; see the class. */
  public static void main(String[] args) throws IOException {
    int status = run(args, System.out, System.err);
    if (status != 0) {
      System.exit(status);
    }
  }

  /** Runs one task, printing to {@code out} and {@code err}; the exit status. */
  static int run(String[] args, PrintStream out, PrintStream err) throws IOException {
    try {
      if ((args.length == 2 || args.length == 3) && args[0].equals("check-lock")) {
        out.print(checkLock(Path.of(args[1]), args.length == 3 ? Path.of(args[2]) : null));
        return 0;
      }
      if (args.length == 3 && args[0].equals("settings-hashes")) {
        JsonValue.Obj.Builder json = JsonValue.Obj.builder();
        settingsHashes(Path.of(args[1])).forEach(json::put);
        write(Path.of(args[2]), Json.pretty(json.build()));
        return 0;
      }
      err.println("Usage: check-lock <lock> [<vendordep>] | settings-hashes <settings> <out.json>");
      return 2;
    } catch (IllegalArgumentException e) {
      err.println(e.getMessage());
      return 1;
    }
  }

  /**
   * Checks the lock (and its version against the vendordep's, when given); what to print (the
   * placeholders left), or an {@link IllegalArgumentException} saying what's wrong.
   */
  static String checkLock(Path lockFile, @org.jspecify.annotations.Nullable Path vendordep)
      throws IOException {
    PhotonVisionLock lock = PhotonVisionLock.parse(read(lockFile));
    if (vendordep != null) {
      List<String> problems = lock.checkAgainst(PhotonVisionLock.vendordepVersion(read(vendordep)));
      if (!problems.isEmpty()) {
        throw new IllegalArgumentException(String.join("\n", problems));
      }
    }
    List<String> placeholders = lock.placeholders();
    if (placeholders.isEmpty()) {
      return "";
    }
    return PhotonVisionLock.PATH
        + ": not yet known, so images can't be built yet: "
        + String.join(", ", placeholders)
        + "\n";
  }

  /** Each computer's committed settings hash, by name: one folder per computer. */
  static Map<String, String> settingsHashes(Path settings) throws IOException {
    Map<String, String> hashes = new TreeMap<>();
    if (!Files.isDirectory(settings)) {
      return hashes;
    }
    try (Stream<Path> folders = Files.list(settings)) {
      for (Path folder : folders.filter(Files::isDirectory).sorted().toList()) {
        if (isEmpty(folder)) {
          continue; // a placeholder: none committed yet
        }
        Optional<Settings> read;
        try {
          read = SettingsFiles.read(folder);
        } catch (RuntimeException e) {
          throw new IllegalArgumentException(folder.getFileName() + ": " + e.getMessage(), e);
        }
        read.ifPresent(found -> hashes.put(folder.getFileName().toString(), found.hash()));
      }
    }
    return hashes;
  }

  private static boolean isEmpty(Path folder) throws IOException {
    try (Stream<Path> files = Files.walk(folder)) {
      // A placeholder (.gitkeep) isn't a setting.
      return files.noneMatch(
          file -> Files.isRegularFile(file) && !file.getFileName().toString().startsWith("."));
    }
  }

  private static String read(Path file) throws IOException {
    if (!Files.isRegularFile(file)) {
      throw new IllegalArgumentException(file + " is missing");
    }
    return Files.readString(file, StandardCharsets.UTF_8);
  }

  private static void write(Path target, String text) throws IOException {
    Path parent = target.toAbsolutePath().getParent();
    if (parent != null) {
      Files.createDirectories(parent);
    }
    Files.writeString(target, text, StandardCharsets.UTF_8);
  }
}
