# Fresh-run check

To check that the portfolio rebuilds from nothing, I cloned the repository at commit `34991ec` into a temporary folder outside the project on 14 November 2026. Three runner files that were not yet committed were copied in: `scripts/runall.py`, `portfolio-5-distributed-cloud/run_p5.py` and `portfolio-5-distributed-cloud/demos/common.py`. I also copied in `.env` and created a new virtual environment from `requirements.txt`. The stack ran under its own Compose project, `itoju-fresh`, so every database started from empty volumes. My own containers were stopped for the duration, because the clone uses the same ports.

```powershell
$env:COMPOSE_PROJECT_NAME = "itoju-fresh"
.venv\Scripts\python scripts\runall.py
```

## Result

All five pipelines passed, with exit code 0, in 29.9 minutes.

| Pipeline | Minutes | Checks in the fresh run | Committed evidence |
|---|---|---|---|
| Portfolio 1 | 0.4 | 69, 28 and 45 tests, 15 consistency checks, catalogue check: all pass | Identical, line for line |
| Portfolio 2 | 19.8 | 15 steps; 15 consistency checks at volume; 10 of 10 tables identical in the determinism check | Same checks |
| Portfolio 3 | 2.4 | 16/16, 9/9, 20/20 | Same |
| Portfolio 4 | 4.9 | 13/13, 16/16, 8/8, 16/16, 7/7, 3/3, 8/8 | Same |
| Portfolio 5 | 2.4 | 16/16, 10/10 | Same |

## Figures that must not move, and did not

- Every Portfolio 1 evidence file was identical to the committed one apart from its header: the build, the four test suites, the normalisation proof and the catalogue check.
- Portfolio 2's data profile and its consistency checks at volume were identical. All 43 result files, covering 15 queries in three phases, had the same row count and result hash.
- In Portfolio 4, every query examined exactly the same number of documents and index keys before and after indexing. The time-series and graph outputs were identical.
- In Portfolio 5, the hashed shard key split the encounters 50,576 to 51,459. The ranged key sent all 5,000 new visits to one shard, while the hashed key shared them 2,493 to 2,507. With a shard down, the partial result was 53,069 documents. All of these were identical to the committed run.

## Figures that moved

- **Times.** Every median and duration moved, as expected on a laptop. For example, the Portfolio 2 baseline of the patient timeline (Q02) took 37.4 ms in the committed run and 93.0 ms in the fresh one. Portfolio 4's latest-visits query without an index took 1,428.7 ms and 708.7 ms. The materialised view's refresh took 6.2 and 9.2 seconds (full, then concurrent) in the committed run, and 3.2 and 2.2 seconds in the fresh one.
- **Synchronous commit.** The fresh medians were 2.017 ms (`off`), 3.189 (`local`), 6.322 (`on`) and 4.934 (`remote_apply`). Waiting for the standby was slower than not waiting in both runs, but `on` and `remote_apply` swapped order. The failover gap was 2.64 s against 2.61 s. 779 writes were acknowledged and none was lost.
- **Buffers.** 11 of the 15 queries read exactly the same number of buffers in every phase. Four did not:
  - Q03b: 13,699 → 13,697
  - Q04: 1,518 → 1,592
  - Q05 from the materialised view: 35 → 64
  - Q07 at baseline: 4,466 → 4,464

  The data were identical, but the physical layout was not. The two GiST exclusion indexes on `appointment` differed by 8 kB and 32 kB, and the materialised view had more pages. I believe the cause is background maintenance running at different moments, but I did not confirm it.
- **Statistics.** `ANALYZE` samples at random. The distinct-patient estimate was 30,114 at the default target and 50,661 at 1,000, against 30,752 and 50,609 in the committed run. Both runs give about half and 87% of the 57,938.
- **Q07 after indexing.** The committed run showed Q07 getting slower with its covering index, from 70 ms to 122 ms, because the plan turned serial. The fresh run turned serial too, but measured 154, 130 and 149 ms, so the slowdown did not reproduce. Only the halving of buffers did.
- **Units in stock.** The Portfolio 4 load found 155,224 units in stock against 155,244 in the committed evidence, and MongoDB matched PostgreSQL in both runs. Portfolio 3's isolation demonstration commits a real 10-unit delivery every time it runs. The committed figure was captured after two more runs of Portfolio 3 than the fresh one.
- **Other expected changes.** The pseudonym key is generated afresh on every build, so the de-identified view showed a different `patient_key`, by design. MongoDB's indexes took 37 MB against 39 MB. The second writer's transaction was retried 12 times against 11.

## Documents corrected

Several documents had relied on figures that moved, and I corrected them:

- The reflection's lesson on buffers no longer rests on Q07's slowdown.
- Its lesson on statistics uses proportions rather than one sample's estimates.
- The Portfolio 2 analysis now says the statistics sample is random and that refresh times varied widely.
- The Portfolio 4 suitability analysis no longer gives the conflict's timing in milliseconds.
- The reproduce times in the Portfolio 2 and Portfolio 4 READMEs now match both runs.

The clone, its virtual environment and all of its volumes were deleted afterwards, and my containers were restarted.
