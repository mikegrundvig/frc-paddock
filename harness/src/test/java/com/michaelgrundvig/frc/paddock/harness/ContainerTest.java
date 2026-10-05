package com.michaelgrundvig.frc.paddock.harness;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.extension.ExtendWith;

/**
 * Marks a test class that runs containers (Docker or Podman). Without a runtime for Linux
 * containers it skips, except in CI on Linux.
 */
@Target(ElementType.TYPE)
@Retention(RetentionPolicy.RUNTIME)
@Tag("container")
@ExtendWith(ContainerRuntime.class)
@interface ContainerTest {}
