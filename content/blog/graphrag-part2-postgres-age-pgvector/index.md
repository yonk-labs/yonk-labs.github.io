---
title: "Getting Apache AGE and pgvector Running on Postgres 16"
date: 2026-04-15
draft: false
tags: ["postgres", "rag", "graphrag", "pgvector", "apache-age", "docker", "tutorial"]
summary: "Part 2 of 3. A complete Docker setup for Postgres 16 with pgvector and Apache AGE, plus your first vector similarity query and your first Cypher traversal — with the gotchas that cost me an afternoon the first time."
---

> **Part 2 of 3** in the GraphRAG on Postgres series. Companion repo: [yonk-labs/graphrag-demo](https://github.com/yonk-labs/graphrag-demo). If you haven't read [Part 1](../graphrag-part1-vector-vs-graph/), start there.

So you read Part 1, you're sold on the idea of running a graph database and a vector store inside the same Postgres instance, and now you're staring at a blinking cursor wondering how the hell you actually install this stuff. I've been there. The first time I tried to get Apache AGE running I lost an afternoon to a branch name typo and another hour to a missing CA certificate. Nobody writes this part down, so here we are.

Here's the good news: it's simpler than it looks once you know the moves. Docker does the gnarly part for you, which is important because there's no reliable pre-built AGE image you can just pull. You're going to build it from source, but Docker is going to hide that fact from you after the first five minutes. By the end of this post you'll have a running Postgres 16 with pgvector and AGE both loaded, and you'll have run your first vector similarity query and your first Cypher traversal against it. Real queries, real output, no hand-waving.

## What you need on your machine

Prerequisites are boring but worth listing so nobody gets 400 words in and realizes they're missing something:

- Docker and Docker Compose. Modern versions. If you're still typing `docker-compose` with a hyphen and it's the old Python script, upgrade. We're using `docker compose` (space, no hyphen) which ships with Docker Desktop and modern Docker Engine.
- About 2GB of free disk for the image build. The base postgres:16 image plus the build toolchain plus the compiled extensions adds up.
- Roughly 5 minutes of patience for the first build. After that it's cached and quick.
- Basic SQL comfort. If you can write a JOIN you're fine.

Notice what's not on the list: a local Postgres install. You don't need one. Docker handles everything.

## The Dockerfile

Here's the whole thing. It's 31 lines. I'll walk through it after.

```dockerfile
FROM postgres:16

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    postgresql-server-dev-16 \
    libreadline-dev \
    zlib1g-dev \
    flex \
    bison \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates

# Build and install pgvector 0.8.0
RUN git clone --branch v0.8.0 --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make OPTFLAGS="" \
    && make install \
    && rm -rf /tmp/pgvector

# Build and install Apache AGE 1.5.0 for PG16
RUN git clone --branch release/PG16/1.5.0 --depth 1 https://github.com/apache/age.git /tmp/age \
    && cd /tmp/age \
    && make install \
    && rm -rf /tmp/age

# Preload AGE so LOAD is not needed per-session
RUN echo "shared_preload_libraries = 'age'" >> /usr/share/postgresql/postgresql.conf.sample

COPY initdb/ /docker-entrypoint-initdb.d/
```

We start from `postgres:16`, the official Debian-based image. Small, standard, well maintained. No reason to get clever here.

The `apt-get install` block pulls the toolchain we need to compile two C extensions. `build-essential` gives us gcc and make. `postgresql-server-dev-16` gives us the Postgres headers and `pg_config`, which the extension Makefiles use to find where to install things. `libreadline-dev` and `zlib1g-dev` are linking dependencies. `flex` and `bison` are parser generators that AGE needs to build its Cypher grammar. `git` is obvious. And `ca-certificates` is the one that bit me the first time. Without it, `git clone https://github.com/...` fails with an SSL error and you sit there wondering why Git can't reach a perfectly reachable host. That `update-ca-certificates` line at the end is cheap insurance.

Then we clone and build pgvector 0.8.0. Standard `make install` flow, nothing exotic. The `OPTFLAGS=""` flag tells pgvector to build without aggressive CPU-specific optimizations, which saves you from weird crashes when the build machine and the run machine have different CPU features. If you know your target CPU exactly you can drop it.

Next, AGE. This is where I lost that afternoon. The AGE repo has tags like `PG16/v1.5.0` and branches like `release/PG16/1.5.0` and they are not the same thing. If you pick the wrong one you get "Remote branch not found in upstream origin" and you start questioning your life choices. The branch we want is `release/PG16/1.5.0`. Write that down. I spent an hour the first time staring at the screen convinced the docs were lying to me. They weren't. I was just reading them wrong.

The second-to-last line appends `shared_preload_libraries = 'age'` to the postgres config template. Without this you'd have to run `LOAD 'age';` at the start of every session, which is the kind of thing you'll forget exactly once before it ruins your week. Preloading means AGE is there the moment Postgres starts.

Last line copies our init scripts into the magic directory.

## The init SQL scripts

Postgres's official Docker image has a nice feature: any `.sql` or `.sh` file dropped into `/docker-entrypoint-initdb.d/` runs the first time Postgres starts with a fresh data volume. First time only. It's perfect for one-time setup that shouldn't run on every container restart.

We've got three files. Here's the first, `01-extensions.sql`:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;
ALTER DATABASE graphrag SET search_path = ag_catalog, "$user", public;
```

Two CREATE EXTENSIONs, one search_path change. That last line matters more than it looks. AGE defines a custom type called `agtype` (think JSON with graph semantics) and it lives in the `ag_catalog` schema. If `ag_catalog` isn't in your search_path, every Cypher query you write is going to fail to resolve the return types and you'll get confusing errors about unknown types. Setting it at the database level means every new connection gets it automatically.

Second file, `02-schema.sql`, creates the documents table that pgvector will live in:

```sql
CREATE TABLE documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    doc_type TEXT NOT NULL,
    author_id TEXT NOT NULL,
    project_id TEXT,
    dataset TEXT NOT NULL DEFAULT 'acme',
    created_at TIMESTAMP DEFAULT NOW(),
    embedding vector(384)
);

CREATE INDEX idx_documents_embedding ON documents
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

CREATE INDEX idx_documents_author ON documents (author_id);
CREATE INDEX idx_documents_project ON documents (project_id);
CREATE INDEX idx_documents_doc_type ON documents (doc_type);
CREATE INDEX idx_documents_dataset ON documents (dataset);
```

The `vector(384)` column holds 384-dimensional embeddings (the default size for the sentence-transformers `all-MiniLM-L6-v2` model, which we'll use in Part 3). The HNSW index is pgvector's graph-based approximate nearest neighbor index. The parameters `m = 16` and `ef_construction = 200` are reasonable defaults for datasets up to about 1 million rows. Bigger datasets want bigger numbers, smaller ones can get away with less. Don't overthink this until you have enough data to measure.

Third file, `03-graph-schema.sql`, sets up the AGE graph and its labels:

```sql
SELECT ag_catalog.create_graph('org_graph');

SELECT ag_catalog.create_vlabel('org_graph', 'Person');
SELECT ag_catalog.create_vlabel('org_graph', 'Team');
SELECT ag_catalog.create_vlabel('org_graph', 'Project');
SELECT ag_catalog.create_vlabel('org_graph', 'Service');
SELECT ag_catalog.create_vlabel('org_graph', 'Technology');

SELECT ag_catalog.create_elabel('org_graph', 'WORKS_ON');
SELECT ag_catalog.create_elabel('org_graph', 'MEMBER_OF');
SELECT ag_catalog.create_elabel('org_graph', 'DEPENDS_ON');
SELECT ag_catalog.create_elabel('org_graph', 'OWNS');
SELECT ag_catalog.create_elabel('org_graph', 'KNOWS_ABOUT');
SELECT ag_catalog.create_elabel('org_graph', 'REPORTS_TO');
SELECT ag_catalog.create_elabel('org_graph', 'AUTHORED');

SELECT ag_catalog.create_vlabel('org_graph', 'Case');
SELECT ag_catalog.create_vlabel('org_graph', 'Justice');
SELECT ag_catalog.create_vlabel('org_graph', 'Issue');

SELECT ag_catalog.create_elabel('org_graph', 'VOTED_MAJORITY');
SELECT ag_catalog.create_elabel('org_graph', 'VOTED_DISSENT');
SELECT ag_catalog.create_elabel('org_graph', 'VOTED_CONCURRING');
SELECT ag_catalog.create_elabel('org_graph', 'WROTE_OPINION');
SELECT ag_catalog.create_elabel('org_graph', 'CITED');
SELECT ag_catalog.create_elabel('org_graph', 'CONCERNS');
```

Here's a thing that trips up every Neo4j refugee: AGE makes you declare vertex labels (`create_vlabel`) and edge labels (`create_elabel`) before you can use them in a Cypher query. Neo4j just lets you conjure labels on the fly in a `CREATE` statement. AGE does not. If you try to `CREATE (:Person)` without first declaring Person as a vertex label, you get an error. It feels like paperwork, but it gives you strict schema enforcement and you adapt fast. The file above declares labels for two datasets in one graph: a generic org structure and the SCOTUS case dataset we'll wire up in Part 3.

## Docker Compose and first run

Here's the compose file:

```yaml
services:
  postgres:
    build:
      context: ./postgres
    environment:
      POSTGRES_DB: graphrag
      POSTGRES_USER: graphrag
      POSTGRES_PASSWORD: graphrag
    ports:
      - "5440:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U graphrag -d graphrag"]
      interval: 5s
      timeout: 5s
      retries: 10

  app:
    build:
      context: ./app
    ports:
      - "8000:8000"
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://graphrag:graphrag@postgres:5432/graphrag
      LLM_PROVIDER: ${LLM_PROVIDER:-claude}
      EMBEDDING_PROVIDER: ${EMBEDDING_PROVIDER:-local}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      OLLAMA_BASE_URL: ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}

volumes:
  pgdata:
```

Two services. Postgres is the one we care about today. It builds from the Dockerfile we just walked through, persists data in a named volume (so you don't lose your graph when you restart), and exposes on port 5440 on the host. Why 5440 and not 5432? Because every developer I know already has something else listening on 5432, and the number of "why isn't my new Postgres starting" debugging sessions I've had would fill a small book. Pick a weird port, save yourself the grief.

The `app` service is the FastAPI app we'll cover in Part 3. Ignore it for now. The healthcheck block on postgres means Compose will wait until Postgres is actually accepting connections before marking it healthy, which matters for the app service.

Commands to bring it up and get a psql prompt:

```bash
git clone https://github.com/yonk-labs/graphrag-demo.git
cd graphrag-demo
docker compose up -d postgres
# Give it a few seconds to start and run the init scripts
docker compose exec postgres psql -U graphrag -d graphrag
```

First build takes about 5 minutes while it compiles the extensions. After that, starts are near-instant.

## Verify the extensions loaded

Inside psql, run these. If the first one comes back with two rows, you're in business.

```sql
SELECT extname, extversion FROM pg_extension WHERE extname IN ('vector', 'age');
```

Expected output:

```
 extname | extversion
---------+------------
 vector  | 0.8.0
 age     | 1.5.0
```

And confirm AGE knows about our graph:

```sql
SELECT * FROM ag_catalog.ag_graph;
```

You'll see one row for `org_graph` with its namespace info. If either of these comes back empty, something went wrong in the init scripts. The most common cause is that the data volume already existed from a previous run. Init scripts only run on a fresh volume. If you need to start over, `docker compose down -v` will delete the volume and the next `up` will re-run everything.

## Your first vector query

Let's put some rows into the documents table and run a similarity search. We'll hand-write toy vectors so you don't need a model running yet. These are not realistic embeddings. They're crafted to make the cosine math easy to eyeball so you can verify the plumbing works end to end:

```sql
-- Insert three test docs with distinct vectors.
-- Each vector is mostly zeros, with a signature value at a known position so
-- cosine similarity is easy to reason about.
INSERT INTO documents (title, content, doc_type, author_id, embedding)
VALUES
  ('Vector Test A', 'apple pie recipe', 'meeting_note', 'tutorial',
   ('[' || array_to_string(array_fill(0.0::real, ARRAY[383]), ',') || ',1.0]')::vector),
  ('Vector Test B', 'grocery shopping list', 'meeting_note', 'tutorial',
   ('[0.5,' || array_to_string(array_fill(0.0::real, ARRAY[382]), ',') || ',0.5]')::vector),
  ('Vector Test C', 'quarterly earnings report', 'meeting_note', 'tutorial',
   ('[' || array_to_string(array_fill(0.0::real, ARRAY[383]), ',') || ',-1.0]')::vector);

-- Query vector: same direction as Test A (zeros then +0.9 at the last slot).
SELECT title,
       1 - (embedding <=> ('[' || array_to_string(array_fill(0.0::real, ARRAY[383]), ',') || ',0.9]')::vector) AS similarity
FROM documents
WHERE author_id = 'tutorial'
ORDER BY embedding <=> ('[' || array_to_string(array_fill(0.0::real, ARRAY[383]), ',') || ',0.9]')::vector
LIMIT 3;
```

The `<=>` operator is pgvector's cosine distance. Lower means closer. Since a lot of people think in terms of similarity (higher is better), the convention is `1 - distance` to flip it into a 0-to-1 similarity score. The `WHERE author_id = 'tutorial'` keeps the query focused on the three toy rows rather than any seed data that might already live in the table.

You should see Test A first with similarity `1.0`, Test B second at roughly `0.707`, and Test C last at `-1.0`. Walk through why: Test A points in exactly the same direction as the query vector (both are zero everywhere except a positive value in the last slot), so cosine similarity is 1. Test B has half its weight in the last slot and half at the start, which lines up partially with the query, giving `1/sqrt(2)`. Test C points in the exact opposite direction at the last slot, so cosine similarity is -1. That's the whole idea of cosine similarity in three rows.

Clean up when you're done so these toy rows don't pollute later queries:

```sql
DELETE FROM documents WHERE author_id = 'tutorial';
```

Real embeddings come from a model. Sentence-transformers running locally, OpenAI's text-embedding-3 line, Cohere, whatever you like. They all produce a float vector of fixed dimension that you stick in that `vector(384)` column. You never hand-write vectors in production. The toy example above exists only to confirm the SQL plumbing is wired correctly. It is not what a real RAG pipeline looks like. In Part 3 we'll swap in a real local model so the similarity scores actually mean something.

## Your first Cypher query

This is the section most Postgres people have been waiting for, because Cypher is probably brand new. Let's create some nodes and an edge:

```sql
SELECT * FROM cypher('org_graph', $$
  CREATE (alice:Person {name: 'Alice', title: 'Engineer'})
  CREATE (bob:Person {name: 'Bob', title: 'Engineer'})
  CREATE (eng:Team {name: 'Engineering'})
  CREATE (alice)-[:MEMBER_OF]->(eng)
  CREATE (bob)-[:MEMBER_OF]->(eng)
  RETURN alice.name, bob.name
$$) AS (alice agtype, bob agtype);
```

Stare at that wrapper for a second because you're going to type it a hundred times. AGE embeds Cypher inside SQL through the `cypher()` function. First argument is the graph name. Second argument is a dollar-quoted string (`$$ ... $$`) containing the actual Cypher. And because Postgres is strict about types, you have to tell it what columns come back, always as `agtype`. So the `AS (alice agtype, bob agtype)` clause at the end maps the Cypher RETURN values to named SQL columns. Miss the AS clause, or get the number of columns wrong, and you get an error.

Inside the Cypher itself, `(alice:Person {name: 'Alice'})` is a node pattern: variable `alice`, label `Person`, properties as JSON-ish. Arrows like `-[:MEMBER_OF]->` are directed edges with a type. The whole syntax was designed to look like ASCII art of a graph, and once you get past the initial weirdness it reads really nicely.

Now let's query what we just wrote:

```sql
SELECT * FROM cypher('org_graph', $$
  MATCH (p:Person)-[:MEMBER_OF]->(t:Team {name: 'Engineering'})
  RETURN p.name, p.title
$$) AS (name agtype, title agtype);
```

`MATCH` is the pattern match verb: "find me every Person that has a MEMBER_OF edge to a Team named Engineering, and return the person's name and title." You'll get Alice and Bob back. Heads up: the values come back with quotes around them, like `"Alice"` instead of `Alice`, because they're `agtype` (basically a JSON scalar) not plain text. In application code you'll either cast them or strip the quotes. Annoying the first time, muscle memory the second time.

A handful of gotchas to save you pain:

- Labels must exist before use. If you forgot a label in `03-graph-schema.sql`, add a `create_vlabel` call and re-run it. Labels are cheap.
- `agtype` is not `text`. Cast with `::text` and strip quotes, or use AGE's helper functions.
- `ag_catalog` must be in your search_path. We set this at the database level in `01-extensions.sql`, but if you create a new user or database you'll need to set it again.

## The "so what" moment

Step back for a second. You now have a single Postgres instance with pgvector storing embeddings and Apache AGE storing graph nodes and edges. You can write a SQL query that does vector similarity search. You can write a Cypher query that does multi-hop graph traversal. And because they're in the same database, you can join between them in a single statement. No two-database sync problem. No dual-writes. No eventual consistency headaches between your vector store and your graph store. One Postgres, one connection pool, one transaction boundary.

That's the foundation. Everything interesting we're going to build in Part 3 rides on top of this setup. If yours is running and the verification queries came back clean, you're ready.

## Part 3 preview

In Part 3, we take this same stack and point it at 391 real Supreme Court cases with justice voting patterns, majority and dissent opinions, and a citation graph you can actually walk. You're going to see multi-hop Cypher queries that no hybrid search can match, and you're going to see exactly where each retrieval approach wins and loses on real data. It's the good stuff. Grab a coffee.

While you're waiting, here's a challenge: go back to the psql prompt and add a third team (call it Product or whatever you like), create a new Person on that team, and then add a `WORKS_ON` edge from one of the existing engineers to a Project node that the Product team `OWNS`. Then write a Cypher query that finds every Person who works on a project owned by a team they're not a member of. The second time you write Cypher it stops feeling foreign. The fifth time, you'll start wondering why more databases don't have it built in.
