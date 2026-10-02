package com.michaelgrundvig.frc.paddock.tools;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.michaelgrundvig.frc.paddock.json.Json;
import com.michaelgrundvig.frc.paddock.settings.Settings;
import com.michaelgrundvig.frc.paddock.settings.SettingsFiles;
import com.michaelgrundvig.frc.paddock.settings.SettingsRow;
import com.michaelgrundvig.frc.paddock.table.Board;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/** Paddock's build tasks, on a team's repository made for each test. */
class PaddockBuildTest {
  static final String VERSION = "v2027.0.0-alpha-2";
  static final String SHA = "edf2bda3032579d759de46aab0e8094cfd3de3586ba764b663470d2b80351cb7";

  /** Paddock's repository, whose recipe's lock is checked. */
  static final Path PROJECT = Path.of(System.getProperty("frc.projectDir", "../.."));

  @TempDir Path root;

  static String lock(String version, String jarSha256) {
    StringBuilder images = new StringBuilder();
    for (Board board : Board.values()) {
      images
          .append(images.length() == 0 ? "" : ",")
          .append("\"")
          .append(board.id())
          .append("\":{\"url\":\"https://example.org/")
          .append(board.id())
          .append(".img.xz\",\"sha256\":\"")
          .append(SHA)
          .append("\"}");
    }
    return "{\"version\":\""
        + version
        + "\",\"jar\":{\"url\":\"https://example.org/photonvision.jar\",\"sha256\":\""
        + jarSha256
        + "\"},\"images\":{"
        + images
        + "}}";
  }

  private Path write(String path, String text) throws IOException {
    Path file = root.resolve(path);
    Files.createDirectories(file.getParent());
    Files.writeString(file, text, StandardCharsets.UTF_8);
    return file;
  }

  @BeforeEach
  void aRepository() throws IOException {
    write("vendordeps/photonlib.json", "{\"name\":\"photonlib\",\"version\":\"" + VERSION + "\"}");
    write("photonvision.lock", lock(VERSION, "PLACEHOLDER: not archived yet"));
  }

  @Test
  void aLockMatchingPhotonLibPassesAndNamesItsPlaceholders() throws IOException {
    Path lock = root.resolve("photonvision.lock");
    Path vendordep = root.resolve("vendordeps/photonlib.json");
    assertThat(PaddockBuild.checkLock(lock, vendordep))
        .isEqualTo(
            "recipes/photonvision-orangepi/photonvision.lock: not yet known, so images can't be"
                + " built yet: jar.sha256\n");
    write("photonvision.lock", lock(VERSION, SHA));
    assertThat(PaddockBuild.checkLock(lock, vendordep)).isEmpty();
    assertThat(PaddockBuild.checkLock(lock, null)).isEmpty();
  }

  @Test
  void aLockForAnotherVersionFailsTheBuild() throws IOException {
    write("photonvision.lock", lock("v2027.1.0", SHA));
    ByteArrayOutputStream err = new ByteArrayOutputStream();
    int status =
        PaddockBuild.run(
            new String[] {
              "check-lock",
              root.resolve("photonvision.lock").toString(),
              root.resolve("vendordeps/photonlib.json").toString()
            },
            new PrintStream(new ByteArrayOutputStream(), true, StandardCharsets.UTF_8),
            new PrintStream(err, true, StandardCharsets.UTF_8));
    assertThat(status).isEqualTo(1);
    assertThat(err.toString(StandardCharsets.UTF_8))
        .contains("locks PhotonVision v2027.1.0, but vendordeps/photonlib.json is " + VERSION)
        .contains("They must match");
  }

  @Test
  void aBrokenLockSaysWhatsWrong() {
    assertThatThrownBy(() -> PhotonVisionLock.parse("{"))
        .hasMessageStartingWith("recipes/photonvision-orangepi/photonvision.lock: line 1");
    assertThatThrownBy(
            () ->
                PhotonVisionLock.parse(
                    "{\"jar\":{\"url\":\"ftp://x\",\"sha256\":\"abc\"},\"images\":{"
                        + "\"orangepi-9\":{},\"orangepi-5\":{\"url\":\"http://x\",\"sha256\":\"x\"}}}"))
        .hasMessageContaining("version is missing")
        .hasMessageContaining("jar.url must be an https:// address or start with PLACEHOLDER")
        .hasMessageContaining("jar.sha256 must be a SHA-256")
        .hasMessageContaining("images: unknown board orangepi-9")
        .hasMessageContaining("images.orangepi-5.url must be an https:// address")
        .hasMessageContaining("images.orangepi-5.sha256 must be a SHA-256")
        .hasMessageContaining("images has no orangepi-5b");
    assertThatThrownBy(() -> PhotonVisionLock.vendordepVersion("{}"))
        .hasMessage("vendordeps/photonlib.json has no version");
  }

  @Test
  void theLockNamesEveryPlaceholder() {
    PhotonVisionLock lock =
        PhotonVisionLock.parse(
            lock(VERSION, SHA)
                .replace("https://example.org/photonvision.jar", "PLACEHOLDER: archive it")
                .replaceFirst(SHA, "PLACEHOLDER: later"));
    assertThat(lock.placeholders()).containsExactly("jar.url", "jar.sha256");
    assertThat(Objects.requireNonNull(lock.images().get(Board.ORANGEPI_5_MAX)).url())
        .isEqualTo("https://example.org/orangepi-5-max.img.xz");
  }

  /** Paddock's real lock, as the recipe builds from it, has no placeholder left. */
  @Test
  void theRecipesLockIsComplete() throws IOException {
    assertThat(PaddockBuild.checkLock(PROJECT.resolve(PhotonVisionLock.PATH), null)).isEmpty();
  }

  @Test
  void eachComputersCommittedSettingsAreHashed() throws IOException {
    Settings settings =
        new Settings(
            2,
            List.of(SettingsRow.fromText("global", "hardwareSettings", Map.of("contents", "{}"))));
    SettingsFiles.write(settings, root.resolve("settings/vision-front"));
    Files.createDirectories(root.resolve("settings/vision-back"));
    Path out = root.resolve("build/settings-hashes.json");
    assertThat(
            PaddockBuild.run(
                new String[] {
                  "settings-hashes", root.resolve("settings").toString(), out.toString()
                },
                System.out,
                System.err))
        .isZero();
    assertThat(Json.parse(Files.readString(out)).asObject("hashes").string("vision-front", ""))
        .isEqualTo(settings.hash());
    write("settings/vision-back/global/x.json", "{");
    assertThatThrownBy(() -> PaddockBuild.settingsHashes(root.resolve("settings")))
        .hasMessageStartingWith("vision-back: ");
    assertThat(PaddockBuild.settingsHashes(root.resolve("nothing"))).isEmpty();
  }

  @Test
  void aWrongCommandIsShownHowToRun() throws IOException {
    ByteArrayOutputStream err = new ByteArrayOutputStream();
    assertThat(
            PaddockBuild.run(
                new String[] {"nope"},
                System.out,
                new PrintStream(err, true, StandardCharsets.UTF_8)))
        .isEqualTo(2);
    assertThat(err.toString(StandardCharsets.UTF_8)).contains("Usage:");
  }
}
