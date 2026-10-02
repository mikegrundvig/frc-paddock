package com.michaelgrundvig.frc.paddock.table;

import com.michaelgrundvig.frc.spotter.table.Computer;
import com.michaelgrundvig.frc.spotter.table.Table;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Paddock's rules for a table, on top of Spotter's: what the PhotonVision recipe needs of each
 * computer. Its board ({@code image.board}) is one Paddock builds for; its camera names are
 * PhotonVision's, which publishes each at {@code /photonvision/<camera>}, so none has a '/' and no
 * two computers share one; and no agent's port is one PhotonVision or the robot uses.
 */
public final class PaddockTable {
  /** The image setting naming a computer's board. */
  public static final String BOARD = "board";

  /** The first of PhotonVision's camera-stream ports: its streams start at 1181, two per camera. */
  public static final int FIRST_STREAM_PORT = 1181;

  /** The last port kept for PhotonVision's camera streams: ten cameras' worth. */
  public static final int LAST_STREAM_PORT = 1200;

  private PaddockTable() {}

  /** Every way the table breaks Paddock's rules; empty when it keeps them all. */
  public static List<String> problems(Table table) {
    List<String> problems = new ArrayList<>();
    portProblem(table.agentPort()).ifPresent(problems::add);
    Map<String, String> cameras = new HashMap<>();
    for (Computer computer : table.computers()) {
      String board = computer.image().getOrDefault(BOARD, "");
      if (board.isEmpty()) {
        problems.add(computer.name() + " has no board: give it image: {board: ...}");
      } else if (Board.byId(board).isEmpty()) {
        problems.add(computer.name() + "'s board \"" + board + "\" isn't one of: " + Board.ids());
      }
      portProblem(computer.agentPort())
          .ifPresent(problem -> problems.add(computer.name() + "'s " + problem));
      for (String camera : computer.cameras()) {
        if (camera.indexOf('/') >= 0) {
          problems.add(
              "camera \""
                  + camera
                  + "\" has a '/'; PhotonVision publishes each camera under /photonvision/<camera>");
        }
        String other = cameras.putIfAbsent(camera, computer.name());
        if (other != null) {
          problems.add(
              "camera "
                  + camera
                  + " is listed by "
                  + other
                  + " and "
                  + computer.name()
                  + "; PhotonVision camera names must be unique on the robot");
        }
      }
    }
    return problems;
  }

  /**
   * Why an agent's port is taken, if it is: by PhotonVision's page or streams, or NetworkTables.
   */
  static Optional<String> portProblem(int port) {
    if (port >= FIRST_STREAM_PORT && port <= LAST_STREAM_PORT) {
      return Optional.of(
          "agentPort "
              + port
              + " is taken: PhotonVision's camera streams use "
              + FIRST_STREAM_PORT
              + " and up, two ports per camera");
    }
    if (port == 5800 || port == 5810) {
      return Optional.of(
          "agentPort "
              + port
              + " is taken: "
              + (port == 5800 ? "PhotonVision's page" : "NetworkTables")
              + " uses it");
    }
    return Optional.empty();
  }
}
