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
 * The container tests' images, each named by a hash of what it's built from: built once, reused
 * until that changes. They're kept as {@code localhost/paddock-test-*}; a runtime's prune removes
 * old ones.
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
        # A board's image starts nothing it doesn't need; neither does this. A container loads no
        # kernel modules of its own: Docker's privileged mode would let it try, and fail.
        RUN systemctl mask getty@.service console-getty.service systemd-firstboot.service \\
              systemd-modules-load.service
        STOPSIGNAL SIGRTMIN+3
        ENTRYPOINT ["/sbin/init"]
        """
            .formatted(DEBIAN),
        Map.of());
  }

  /** {@link #base} with NetworkManager, the default network adapter's program. */
  static String networked() {
    return build(
        "networked",
        """
        FROM %s
        RUN apt-get update -qq \\
         && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \\
              network-manager \\
         && apt-get clean && rm -rf /var/lib/apt/lists/*
        """
            .formatted(base()),
        Map.of());
  }

  /**
   * A read-only image as the engine builds one, on {@link #networked}: run-steps.sh,
   * finish-root.sh, and stamp.sh for one computer, from plan.sh's plan. In place of fetch.sh, the
   * package is built from the repository's {@code package/} and the download is its {@code
   * download/}. The kept paths' contents are the /data volume. The runtime owns /etc/hostname and
   * /etc/hosts, so stamping writes into a folder copied over the root without them.
   */
  static String stamped(Path engine, Path plan, Path repo, String image, String computer) {
    Map<String, Object> context = new LinkedHashMap<>();
    context.put("engine", engine);
    context.put("plan", plan);
    context.put("repo", repo);
    return build(
        "stamped",
        """
        FROM %s
        COPY engine /paddock-build/engine
        COPY plan /paddock-build/plan
        COPY repo /paddock-build/repo
        RUN mkdir -p /paddock-build/inputs/packages /paddock-build/inputs/downloads \\
         && dpkg-deb --root-owner-group --build /paddock-build/repo/package \\
              /paddock-build/inputs/packages/00-package.deb >/dev/null \\
         && for file in /paddock-build/repo/download/*; do \\
              cp "$file" "/paddock-build/inputs/downloads/00-${file##*/}"; done \\
         && bash /paddock-build/engine/run-steps.sh --plan /paddock-build/plan --image %s \\
              --config-dir /paddock-build/repo --inputs /paddock-build/inputs \\
         && bash /paddock-build/engine/finish-root.sh --plan /paddock-build/plan --image %s \\
              --keep-out /data --root-id LABEL=rootfs \\
         && mkdir -p /stamp/etc /stamp/usr/lib \\
         && cp -a /etc/os-release /stamp/etc/ && cp -a /usr/lib/os-release /stamp/usr/lib/ \\
         && bash /paddock-build/engine/stamp.sh --plan /paddock-build/plan --computer %s \\
              --root /stamp \\
         && rm /stamp/etc/hostname /stamp/etc/hosts && cp -a /stamp/. / \\
         && rm -rf /stamp /paddock-build
        # A container's root is mounted by its runtime (read-only, here), not from a device by fstab.
        RUN systemctl mask systemd-remount-fs.service
        VOLUME /data
        """
            .formatted(networked(), image, image, computer),
        context);
  }

  /**
   * A machine for local-build.sh, run privileged with this machine's /dev: {@link #networked}'s
   * files at /rootfs (a base is made from them), local-build.sh's tools with this machine's yq, and
   * a stand-in curl serving /served's files by name.
   */
  static String builder(Path engine, Path yq) {
    Map<String, Object> context = new LinkedHashMap<>();
    context.put("engine", engine);
    context.put("yq", yq);
    context.put(
        "curl",
        """
        #!/bin/bash
        # curl --output FILE URL: copies /served's file of the URL's name, or fails as a 404 would.
        out="" url=""
        while (($#)); do
          case $1 in
            --output) out=$2; shift 2 ;;
            -*) shift ;;
            *) url=$1; shift ;;
          esac
        done
        cp "/served/${url##*/}" "$out" 2>/dev/null || { echo "curl: (22) 404: $url" >&2; exit 22; }
        """);
    return build(
        "builder",
        """
        FROM %s AS rootfs
        FROM %s
        RUN apt-get update -qq \\
         && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \\
              e2fsprogs fdisk util-linux mount xz-utils gzip git dpkg procps \\
         && apt-get clean && rm -rf /var/lib/apt/lists/*
        COPY --from=rootfs / /rootfs
        COPY engine /paddock/engine
        COPY yq curl /usr/local/bin/
        RUN chmod 0755 /usr/local/bin/yq /usr/local/bin/curl
        """
            .formatted(networked(), DEBIAN),
        context);
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
