package com.michaelgrundvig.frc.paddock.harness;

import com.github.dockerjava.api.exception.NotFoundException;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.stream.Stream;
import org.testcontainers.DockerClientFactory;
import org.testcontainers.images.builder.ImageFromDockerfile;

/**
 * Images for the container tests, each built once and named by a hash of everything it's built
 * from, so an image already built is reused and a change builds a new one. {@link #base} is Debian
 * 13 under systemd. Built images are kept (named {@code localhost/paddock-test-*}); a runtime's own
 * prune removes old ones.
 */
final class Images {
  /** Debian 13 (trixie), pinned. */
  static final String DEBIAN =
      "docker.io/library/debian:trixie-20260918-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a";

  private static final Map<String, String> BUILT = new LinkedHashMap<>();

  private Images() {}

  /** The base: Debian 13 under systemd, with D-Bus and curl. */
  static String base() {
    return build(
        "base",
        """
        FROM %s
        ENV container=docker
        RUN apt-get update -qq \\
         && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \\
              systemd systemd-sysv dbus curl ca-certificates \\
         && apt-get clean && rm -rf /var/lib/apt/lists/*
        # A board's image starts nothing it doesn't need; neither does this.
        RUN systemctl mask getty@.service console-getty.service systemd-firstboot.service
        STOPSIGNAL SIGRTMIN+3
        ENTRYPOINT ["/sbin/init"]
        """
            .formatted(DEBIAN),
        Map.of());
  }

  /** A path the build gives the tests as a system property. */
  static Path property(String name) {
    String value = System.getProperty(name);
    if (value == null) {
      throw new IllegalStateException(name + " isn't set: run the container tests with Gradle");
    }
    return Path.of(value);
  }

  /**
   * Builds an image unless one built from the same Dockerfile and context is there already.
   *
   * @param context each file in the build's context: a {@link Path} (a file or a folder) or text
   */
  static synchronized String build(String kind, String dockerfile, Map<String, Object> context) {
    String name = "localhost/paddock-test-" + kind + ":" + hash(dockerfile, context);
    String built = BUILT.get(name);
    if (built != null) {
      return built;
    }
    boolean present;
    try {
      DockerClientFactory.instance().client().inspectImageCmd(name).exec();
      present = true;
    } catch (NotFoundException e) {
      present = false;
    }
    if (!present) {
      ImageFromDockerfile image =
          new ImageFromDockerfile(name, false).withFileFromString("Dockerfile", dockerfile);
      context.forEach(
          (file, content) -> {
            if (content instanceof Path) {
              image.withFileFromPath(file, (Path) content);
            } else {
              image.withFileFromString(file, (String) content);
            }
          });
      image.get();
    }
    BUILT.put(name, name);
    return name;
  }

  /** A hash of what an image is built from. */
  private static String hash(String dockerfile, Map<String, Object> context) {
    try {
      MessageDigest digest = MessageDigest.getInstance("SHA-256");
      digest.update(dockerfile.getBytes(StandardCharsets.UTF_8));
      for (Map.Entry<String, Object> file : context.entrySet()) {
        digest.update(file.getKey().getBytes(StandardCharsets.UTF_8));
        Object content = file.getValue();
        if (content instanceof Path) {
          Path path = (Path) content;
          if (Files.isDirectory(path)) {
            try (Stream<Path> walk = Files.walk(path)) {
              for (Path each : walk.sorted().toList()) {
                digest.update(path.relativize(each).toString().getBytes(StandardCharsets.UTF_8));
                if (Files.isRegularFile(each)) {
                  digest.update(Files.readAllBytes(each));
                  digest.update(Files.isExecutable(each) ? (byte) 1 : (byte) 0);
                }
              }
            }
          } else if (Files.size(path) < (1 << 22)) {
            digest.update(Files.readAllBytes(path));
          } else {
            // A large file is known by its size and time.
            digest.update(
                (Files.size(path) + "@" + Files.getLastModifiedTime(path))
                    .getBytes(StandardCharsets.UTF_8));
          }
        } else {
          digest.update(((String) content).getBytes(StandardCharsets.UTF_8));
        }
      }
      return HexFormat.of().formatHex(digest.digest()).substring(0, 16);
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }
}
