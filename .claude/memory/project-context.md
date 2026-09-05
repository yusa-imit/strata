# strata — Project Context

## Current State (2026-09-05)

- **Phase**: Bootstrap complete. Next: Phase 1 (see `docs/milestones.md`)
- **Version**: 0.1.0 (unreleased)
- **Build**: `zig build test` green on skeleton
- **CI**: workflow registered, first run pending

## Immediate Next Steps

- 1A: CRC32C(하드웨어 감지 + 폴백)와 varint — 테스트: 표준 벡터, 경계값, hw/sw 일치
- 1B: `File` with `SyncPolicy` — 테스트: tmpDir에서 writeAt/readAt/sync/preallocate/lock
- 1D: 크래시 주입 하네스 — 테스트: 절단 지점 열거, 생성된 파일이 지정 오프셋에서 끝나는지

## Session Log

**Session 0 (2026-09-05) — Bootstrap**
- Repository scaffolded from `citadel/templates/repo` by `citadel/scripts/scaffold.py`
- PRD written (`docs/PRD.md`), milestones enumerated, agent/command definitions installed
- Module stubs compile; each module has a placeholder test
