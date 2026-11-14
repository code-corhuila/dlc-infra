# Changelog

All notable changes of `dlc-infra` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow
[Semantic Versioning](https://semver.org/). A release is tagged `v<version>` once it is merged into `main`.

## [Unreleased]

## [3.0.0] - 2026-11-14

The changelog starts at this release.

### Added

- Add local stack startup script.
- Add local platform Compose services.
- Add local database initialization Compose stages.
- Add runtime preparation and provisioning scripts.
- Orchestrate fresh local application deployment.
- Configure local notification delivery and runtime access.
- Run develop, qa and main stage databases.
- Start complete develop and qa stages.

### Fixed

- Strip CRLF from the stage certificate script.
- Restart stage database engines with Docker.
