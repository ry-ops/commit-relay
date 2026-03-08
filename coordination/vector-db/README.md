# Vector Database for Enhanced RAG Retrieval

## Overview

The vector database enhances RAG (Retrieval Augmented Generation) with semantic similarity search. Instead of simple keyword matching, we use vector embeddings to find semantically similar past operations.

## Architecture

```
coordination/vector-db/
├── README.md (this file)
├── embeddings/
│   ├── routing-decisions.jsonl      # MoE routing decision embeddings
│   ├── worker-outcomes.jsonl        # Worker execution outcome embeddings
│   ├── vulnerability-history.jsonl   # Security vulnerability embeddings
│   └── implementation-patterns.jsonl # Development pattern embeddings
└── indexes/
    ├── routing-index.json           # Fast lookup index for routing decisions
    ├── worker-index.json            # Fast lookup index for worker outcomes
    ├── vulnerability-index.json     # Fast lookup index for vulnerabilities
    └── implementation-index.json    # Fast lookup index for implementations
```

## Embedding Format

Each embedding entry contains:

```json
{
  "id": "routing-decision-001",
  "timestamp": "2025-11-07T19:30:00Z",
  "source": "coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl",
  "content": {
    "description": "Security vulnerability scan for repository XYZ",
    "routing_decision": "security",
    "confidence": 0.95,
    "keywords": ["security", "vulnerability", "scan"]
  },
  "embedding": [0.123, -0.456, 0.789, ...], // 384-dimensional vector
  "metadata": {
    "master": "coordinator",
    "outcome": "success",
    "tokens_used": 1200
  }
}
```

## Usage

### 1. Generate Embeddings

```bash
# Generate embeddings for historical routing decisions
./scripts/vector-db/generate-embeddings.sh routing-decisions

# Generate embeddings for worker outcomes
./scripts/vector-db/generate-embeddings.sh worker-outcomes

# Generate all embeddings
./scripts/vector-db/generate-all-embeddings.sh
```

### 2. Query for Similar Operations

```bash
# Find similar past routing decisions
./scripts/vector-db/query-similar.sh \
  --type routing-decisions \
  --query "security scan for vulnerability in dependencies" \
  --top-k 5

# Output: Top 5 most similar routing decisions with confidence scores
```

### 3. Hybrid RAG+Vector Workflow

```
User Query: "Scan all repositories for CVE-2024-1234"
    ↓
1. [Vector DB] Find top-5 similar past CVE responses (semantic search)
    ↓
2. [RAG] Retrieve detailed context for those 5 operations
    ↓
3. [CAG] Use cached worker specs + coordination protocol
    ↓
4. [LLM] Generate action plan with enriched context
```

## Implementation Details

### Embedding Model

Currently using **sentence-transformers/all-MiniLM-L6-v2**:
- Dimensions: 384
- Performance: Fast inference (~50ms per embedding)
- Quality: Good for semantic similarity in technical domains
- Size: 80MB model
- License: Apache 2.0

### Similarity Metric

Using **cosine similarity** for vector comparison:
```
similarity(A, B) = (A · B) / (||A|| * ||B||)
```

Scores range from -1 to 1:
- 1.0: Identical vectors (perfect match)
- 0.9-1.0: Very similar
- 0.7-0.9: Similar
- 0.5-0.7: Somewhat related
- <0.5: Not very related

### Storage Format

Embeddings stored as JSONL (JSON Lines) for:
- Easy streaming processing
- Incremental updates
- Simple tooling (jq, grep work out of the box)
- Human-readable format

### Index Structure

Fast lookup indexes stored as JSON for:
- Metadata-based filtering (by master, outcome, date range)
- Quick access to embedding location
- Statistics and analytics

## Performance

| Operation | Latency | Notes |
|-----------|---------|-------|
| Generate embedding | ~50ms | Per document |
| Query top-K (1000 docs) | ~100ms | Linear scan |
| Query top-K (10k docs) | ~500ms | Linear scan |
| Query top-K (100k docs) | ~3s | Need FAISS/Annoy for this scale |

## Future Enhancements

### Phase 1: Basic (Current)
- ✅ JSONL storage for embeddings
- ✅ Linear scan for similarity search
- ✅ Good for <10k documents

### Phase 2: Optimized Indexing
- [ ] Add FAISS index for sub-linear search
- [ ] Support for 100k+ documents
- [ ] Sub-100ms queries

### Phase 3: Real-time Updates
- [ ] Incremental embedding generation
- [ ] Background indexing daemon
- [ ] Automatic re-indexing on new data

### Phase 4: Advanced Features
- [ ] Multi-vector search (combine multiple queries)
- [ ] Hybrid search (keyword + semantic)
- [ ] Relevance feedback learning

## Example Queries

### Find Similar CVE Responses

```bash
./scripts/vector-db/query-similar.sh \
  --type vulnerability-history \
  --query "Critical authentication bypass CVE in Express.js" \
  --top-k 3

# Returns:
# 1. CVE-2024-0001: Authentication bypass in Express 4.x (similarity: 0.92)
# 2. CVE-2023-5678: Session hijacking in Node.js middleware (similarity: 0.84)
# 3. CVE-2023-1234: Authorization flaw in JWT library (similarity: 0.79)
```

### Find Similar Implementation Patterns

```bash
./scripts/vector-db/query-similar.sh \
  --type implementation-patterns \
  --query "Add real-time WebSocket updates to dashboard" \
  --top-k 5

# Returns similar past implementations with WebSocket, real-time, dashboard
```

### Find Similar Worker Outcomes

```bash
./scripts/vector-db/query-similar.sh \
  --type worker-outcomes \
  --query "Multi-repo security scan with 6 workers" \
  --top-k 5

# Returns past multi-repo operations for reference
```

## Integration with Masters

### Security Master

```markdown
**Enhanced RAG Workflow**:
1. CAG: Load worker specs, SLA thresholds (instant)
2. Vector DB: Find top-5 similar CVE responses (100ms)
3. RAG: Retrieve full context for those 5 (200ms)
4. Decision: Spawn workers with enriched context

Total: ~300ms (vs 500ms+ with keyword-only RAG)
```

### Development Master

```markdown
**Enhanced RAG Workflow**:
1. CAG: Load worker specs, quality gates (instant)
2. Vector DB: Find top-5 similar features (100ms)
3. RAG: Retrieve implementation details (200ms)
4. Decision: Create execution plan

Total: ~300ms with better context quality
```

## Maintenance

### Rebuild Indexes

```bash
# Rebuild all indexes from scratch
./scripts/vector-db/rebuild-indexes.sh

# Rebuild specific index
./scripts/vector-db/rebuild-indexes.sh routing-decisions
```

### Monitor Index Health

```bash
# Check index statistics
./scripts/vector-db/index-stats.sh

# Output:
# routing-decisions: 1,234 embeddings, 456MB, last updated: 2025-11-07
# worker-outcomes: 5,678 embeddings, 2.1GB, last updated: 2025-11-07
```

## Technical Notes

### Why JSONL Instead of SQLite/PostgreSQL?

1. **Simplicity**: No database server required
2. **Portability**: Works anywhere with jq
3. **Git-friendly**: Can version control embeddings
4. **Streaming**: Can process incrementally
5. **Debugging**: Human-readable format

### When to Upgrade?

Consider upgrading to proper vector DB (FAISS, Pinecone, Weaviate) when:
- >100k documents (linear scan gets slow)
- Need sub-100ms queries
- Multi-user concurrent access
- Real-time updates critical

### Embedding Model Choice

We chose **all-MiniLM-L6-v2** because:
- Fast: 50ms inference on CPU
- Small: 80MB model size
- Quality: Good for technical text
- Free: Apache 2.0 license
- Proven: Widely used in production

Alternative models:
- **all-mpnet-base-v2**: Better quality, 2x slower
- **ada-002** (OpenAI): Best quality, API cost
- **e5-base-v2**: Good balance, MIT license

## References

- Sentence Transformers: https://www.sbert.net/
- FAISS: https://github.com/facebookresearch/faiss
- Vector Search: https://www.pinecone.io/learn/vector-search/
