package com.michaelgrundvig.frc.paddock.harness;

import com.michaelgrundvig.frc.paddock.json.Json;
import com.michaelgrundvig.frc.paddock.json.JsonValue;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/**
 * PhotonVision's image for the container tests, on {@link Images#base}: Debian 13 under systemd
 * with PhotonVision's jar (pinned) on a Java of its own, on the path as a board's Java is (its
 * smoke test run, so its native libraries are in place on the read-only root); its unit with {@code
 * -n}, as the recipe's drop-in sets it; its settings on /data.
 */
final class PhotonVisionImages {
  /** The Java PhotonVision runs on in its image: 25, as its 2027 builds need. */
  static final String PHOTONVISION_JAVA = "docker.io/library/eclipse-temurin:25.0.4.1_1-jre-noble";

  private PhotonVisionImages() {}

  static String photonVision() {
    Map<String, Object> context = new LinkedHashMap<>();
    context.put("photonvision.jar", PhotonVisionJar.path());
    context.put("photonvision.service", resource("photonvision.service"));
    return Images.build(
        "photonvision",
        """
        FROM %s AS java
        FROM %s
        COPY --from=java /opt/java/openjdk /opt/photonvision/jre
        # PhotonVision's Java is the board's: on every unit's path, as /usr/bin/java is on a board.
        RUN ln -s /opt/photonvision/jre/bin/java /usr/local/bin/java
        COPY photonvision.jar /opt/photonvision/photonvision.jar
        # Its smoke test makes its empty settings and unpacks its native libraries under root's
        # home, where they must be before the root goes read-only.
        RUN mkdir -p /tmp/smoke && cd /tmp/smoke \\
         && /opt/photonvision/jre/bin/java -jar /opt/photonvision/photonvision.jar --smoketest -n \\
         && rm -rf /tmp/smoke
        COPY photonvision.service /etc/systemd/system/
        RUN mkdir -p /data/photonvision_config \\
         && ln -s /data/photonvision_config /opt/photonvision/photonvision_config \\
         && systemctl enable photonvision.service
        VOLUME /data
        """
            .formatted(PHOTONVISION_JAVA, Images.base()),
        context);
  }

  /** A resource of the harness's, as text. */
  static String resource(String name) {
    try (InputStream in =
        Objects.requireNonNull(
            PhotonVisionImages.class.getResourceAsStream("/harness/" + name),
            "no resource harness/" + name)) {
      return new String(in.readAllBytes(), StandardCharsets.UTF_8);
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  /**
   * The PhotonVision jar the tests run, for x86 Linux: pinned by its SHA-256 in {@code
   * harness/photonvision-x86.json}, downloaded once into Gradle's caches and checked.
   */
  static final class PhotonVisionJar {
    private PhotonVisionJar() {}

    private static JsonValue.Obj pin() {
      return Json.parse(resource("photonvision-x86.json")).asObject("photonvision-x86.json");
    }

    /** The pinned version. */
    static String version() {
      return pin().string("version", "");
    }

    /** The jar, downloaded if it isn't cached yet, and checked against its pin. */
    static synchronized Path path() {
      JsonValue.Obj pin = pin();
      String sha256 = pin.string("sha256", "");
      Path jar =
          Images.property("paddock.downloadCache").resolve("photonvision").resolve(sha256 + ".jar");
      try {
        if (!Files.isRegularFile(jar)) {
          Files.createDirectories(jar.getParent());
          Path part = jar.resolveSibling(sha256 + ".part");
          HttpClient client =
              HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build();
          HttpResponse<Path> got =
              client.send(
                  HttpRequest.newBuilder(URI.create(pin.string("url", ""))).build(),
                  HttpResponse.BodyHandlers.ofFile(part));
          if (got.statusCode() != 200) {
            throw new IOException("downloading PhotonVision's jar answered " + got.statusCode());
          }
          if (!sha256(part).equals(sha256)) {
            Files.delete(part);
            throw new IOException("PhotonVision's jar isn't the one pinned (its SHA-256 differs)");
          }
          Files.move(part, jar, StandardCopyOption.ATOMIC_MOVE);
        }
        return jar;
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new IllegalStateException(e);
      }
    }

    private static String sha256(Path file) throws IOException {
      try (InputStream in = Files.newInputStream(file)) {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] chunk = new byte[1 << 16];
        int read;
        while ((read = in.read(chunk)) != -1) {
          digest.update(chunk, 0, read);
        }
        return HexFormat.of().formatHex(digest.digest());
      } catch (NoSuchAlgorithmException e) {
        throw new IllegalStateException(e);
      }
    }
  }
}
