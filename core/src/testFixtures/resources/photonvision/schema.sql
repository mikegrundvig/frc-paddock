-- SPDX-License-Identifier: GPL-3.0-or-later
-- Adapted from PhotonVision (https://github.com/PhotonVision/photonvision), Copyright (C) Photon
-- Vision, under the GNU General Public License, version 3 or later: the SQL of its DatabaseSchema's
-- migrations. This file alone keeps PhotonVision's license (THIRD-PARTY.md); it's a test fixture,
-- and in no image.
--
-- PhotonVision's settings database, photon.sqlite, as its migrations make it: DatabaseSchema in
-- photon-core (org.photonvision.common.configuration), at the version the tests' PhotonLib
-- pins. Migration 1 creates the tables, migration 2 adds otherpaths_json, and user_version counts
-- the migrations run. Transcribed for the unit tests, which need no PhotonVision jar; the
-- container tests run the pinned jar itself.
CREATE TABLE IF NOT EXISTS global (
 filename TINYTEXT PRIMARY KEY,
 contents mediumtext NOT NULL
);
CREATE TABLE IF NOT EXISTS cameras (
 unique_name TINYTEXT PRIMARY KEY,
 config_json text NOT NULL,
 drivermode_json text NOT NULL,
 pipeline_jsons mediumtext NOT NULL
 );
ALTER TABLE cameras ADD COLUMN otherpaths_json TEXT NOT NULL DEFAULT '[]';
PRAGMA user_version = 2;
