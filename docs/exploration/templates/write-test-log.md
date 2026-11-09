# Write tests, <YYYY-MM-DD>

<!-- Copy to data/<vendor>-<model>/write-tests-<date>.md.
     data/write-tests-2026-11-04.md is the HP E27m G4's, a complete example. -->

<Monitor>, firmware <x>, over <connection>, from <Mac> on macOS <version>. Each test wrote a value, waited 1–1.5 s, read the code back three times, diffed every readable code, and restored the original. <Someone watched the screen / Nobody watched the screen>.

## Baseline (<n> readable codes)

```
<paste: ./glim scan | awk '{print $1, $4}'>
```

## Accepted, reads back what was written

| Code | Written | Restored to | Diff of the other codes | Seen on screen |
| --- | --- | --- | --- | --- |

## Accepted with side effects

| Code | Written | Other codes that moved | How to undo |
| --- | --- | --- | --- |

## Stored differently

| Code | Written | Reads back (3×) | Notes |
| --- | --- | --- | --- |

## Accepted and ignored

| Code | Written | Stays at | Likely reason |
| --- | --- | --- | --- |

## One-shot actions (05 06 08 …)

| Code | Diff after writing 1 |
| --- | --- |

## Not tested, and why

- <codes in the hazard tier, deferred by the owner, …>

## End state

```
<paste: ./glim scan | awk '{print $1, $4}' | diff baseline.txt -    → only counters>
```
