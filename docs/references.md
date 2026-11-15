# References

APA 7th edition.

## Course material

Miva Open University. (2025). *MIT 8103: Advanced database systems* [Course material]. Miva Open University.

Miva Open University. (2026). *MIT 8103 Advanced Database Systems: Continuous assessment, September cohort 2026* [Assessment brief]. Miva Open University.

## Books and articles

Abadi, D. (2012). Consistency tradeoffs in modern distributed database system design: CAP is only part of the story. *Computer, 45*(2), 37–42. https://doi.org/10.1109/MC.2012.33

Chen, P. P.-S. (1976). The entity-relationship model: Toward a unified view of data. *ACM Transactions on Database Systems, 1*(1), 9–36. https://doi.org/10.1145/320434.320440

Elmasri, R., & Navathe, S. B. (2016). *Fundamentals of database systems* (7th ed.). Pearson.

Silberschatz, A., Korth, H. F., & Sudarshan, S. (2020). *Database system concepts* (7th ed.). McGraw-Hill Education.

## Legislation

Federal Republic of Nigeria. (2023). *Nigeria Data Protection Act, 2023*.

## Technical documentation

Docker Inc. (n.d.). *Docker Compose documentation*. Retrieved November 14, 2026, from https://docs.docker.com/compose/

Graphviz. (n.d.). *Graphviz documentation*. Retrieved November 14, 2026, from https://graphviz.org/documentation/

MongoDB, Inc. (n.d.-a). *MongoDB manual* (Version 7.0). Retrieved November 14, 2026, from https://www.mongodb.com/docs/v7.0/

MongoDB, Inc. (n.d.-b). *PyMongo documentation*. Retrieved November 14, 2026, from https://pymongo.readthedocs.io/

PostgreSQL Global Development Group. (n.d.). *PostgreSQL 16 documentation*. Retrieved November 14, 2026, from https://www.postgresql.org/docs/16/

Psycopg Team. (n.d.). *Psycopg 3 documentation*. Retrieved November 14, 2026, from https://www.psycopg.org/psycopg3/docs/

Python Software Foundation. (n.d.). *Python 3.13 documentation*. Retrieved November 14, 2026, from https://docs.python.org/3.13/

## Software

| Software | Version | Used for |
|---|---|---|
| PostgreSQL | 16.15 (`postgres:16` image, pinned by digest) | The relational database in Portfolios 1–3 and the replication cluster in Portfolio 5 |
| MongoDB | 7.0.45 (`mongo:7.0` image, pinned by digest) | The document model in Portfolio 4 and the sharded cluster in Portfolio 5 |
| Docker Engine and Docker Compose | 28.4.0 and 2.39.2 | Running every server |
| Python | 3.13.5 | Pipelines, demonstrations and evidence capture |
| psycopg | 3.3.6 | PostgreSQL driver |
| PyMongo and dnspython | 4.19.0 and 2.9.0 | MongoDB driver |
| tabulate | 0.10.0 | Tables in the evidence files |
| tzdata | 2026.6 | Lagos time in the evidence headers |
| Graphviz | 16.1.1 | Drawing the ER diagrams |
| Microsoft Edge (headless) | 157.0.4341.46 | Printing the LMS summary to PDF |

## Data

All data in this repository is synthetic, and Itoju Clinics is a fictional organisation. The Portfolio 1 sample data was written by hand. The volume data in Portfolio 2 is generated inside PostgreSQL by [volume.sql](../portfolio-2-query-optimisation/sql/volume.sql), which derives every value from a hash of a row number and a fixed seed, so each rebuild produces the same rows. The pipeline checks this by building the data twice and comparing them. Names come from a short invented list, national-ID-like numbers begin with 999 and phone numbers begin with +2340. The MongoDB documents in Portfolio 4 and the sharded cluster in Portfolio 5 are built from that PostgreSQL data. The home blood-pressure readings and the referral network in Portfolio 4 are generated deterministically from the same patients and clinicians.

## AI assistance

Anthropic. (2026). *Claude Code* (Claude Opus 5.5) [Large language model coding assistant]. https://claude.com/claude-code

How I used it, and how I checked what it produced, is set out in the [AI use declaration](ai-use-declaration.md) and the [AI assistance log](ai-assistance-log.md).
