# AI assistance log

I used Claude Code (Anthropic), running the Claude Opus 5.5 model (`claude-opus-5-5`), as a coding and writing assistant throughout this portfolio. I chose the case study and specified the architecture, technology stack, data conventions and order of work. I made the design decisions, specified each piece of work, and reviewed, ran and tested what the assistant produced, changing it where needed before committing it. The assistant generated scripts and drafted documentation to my specification, which saved time on repetitive work.

Each entry below separates what I decided from recommendations the assistant made that I accepted when I reviewed them.

## Phase 0: Discovery and overall plan (2026-11-14)

**My decisions:** I chose the outpatient clinic and diagnostics network as the case study and chose the name Itoju Clinics from three candidates the assistant proposed. I set the deadline, decided to commit at each milestone and decided how my name appears in the documents.

**Design decisions (approved at review):** None at this stage.

**AI assistance used:** The assistant inspected the empty repository, the installed tools and the free ports without changing anything. It read the CA brief, rendered the scanned course text's contents pages to images and mapped its sessions to page numbers, proposed three fictional organisation names and checked each against web searches for existing Nigerian providers, and drafted the overall plan.

**How it was verified:** I reviewed the findings and the plan before any file was created. The course page map was checked against the printed page numbers of ten pages; the offset between PDF and printed page numbers changes by one after printed page 145, and the map records this.

## Phase 1: Repository scaffold and case-study statement (2026-11-14)

**My decisions:** I approved the scaffold plan and the stack: PostgreSQL 16 and MongoDB 7.0 in Docker, bound to 127.0.0.1 on non-default ports, with Python pipelines and every piece of evidence captured through one helper. I approved installing Graphviz for the ER diagram.

**Design decisions (approved at review):** Pinning both Docker images by digest. Initialising PostgreSQL with the `C.UTF-8` collation and data checksums. Keeping only secrets in `.env`, so the evidence helper can redact every `.env` value without garbling ordinary output.

**AI assistance used:** The assistant generated `compose.yaml`, `scripts/evidence.py`, the two environment checks in `scripts/environment/`, `.gitignore`, `.gitattributes`, `.env.example` and `requirements.txt`, and drafted the root README with the case-study statement and the five portfolio READMEs. During implementation it made three changes to the plan: it pinned the Python packages to the newest releases at least two weeks old (psycopg 3.3.6 rather than 3.3.9 and pymongo 4.19.0 rather than 4.20.0, both of which were two days old); it pinned pymongo's dependency dnspython, which `pip freeze` showed was otherwise unpinned; and it ran MongoDB on port 37017 inside the container as well as on the host, because a MongoDB service already occupies port 27017 on this machine and a driver following the replica set's advertised address would otherwise have reached it.

**How it was verified:**

- `docker compose up -d --wait` brought both containers to healthy in 28 seconds without pulling any image.
- PostgreSQL reported 16.15, UTF8 encoding, `C.UTF-8` collation and data checksums on. MongoDB reported 7.0.45 as PRIMARY of replica set `rs0` with keyfile authentication, and committed a multi-document transaction.
- From the host, psycopg and pymongo both connected; pymongo's replica-set discovery returned `localhost:37017`, confirming it reached the container rather than the local service.
- The evidence helper was tested before use: a command exiting with 3 made it exit with 3, a missing program gave 127, every `.env` value was replaced by its marker, and no secret appeared in any test output.
- A fresh virtual environment installed the pinned packages exactly and `pip check` reported no broken requirements.
- Problems found and fixed: the evidence header showed Windows commands with POSIX quoting that was hard to read, so it now uses the platform's own quoting; dnspython was unpinned, as noted above.
