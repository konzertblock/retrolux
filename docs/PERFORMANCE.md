# Performance (synthetic library)

`swift test --filter testSyntheticLibraryScale` (`RL_PERF=1` für 100 000). Apple Silicon, Debug-Build, Referenzmedien ohne Bilddaten
(Metadaten/Index, keine Thumbnails):

| Versionen | Einfügen | Öffnen (Index laden) | Filter (Bewertung + Schlagwort) |
|---|---|---|---|
| 10 000 | 0,19 s | 0,06 s | 1 ms |
| 100 000 | 1,95 s | 0,67 s | 15 ms |

Nicht gemessen: Thumbnail-Erzeugung und Bildrendering großer Bibliotheken (hängen von den Medien ab).
