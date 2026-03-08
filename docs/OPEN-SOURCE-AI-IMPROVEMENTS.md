# Open Source AI Architecture Improvements

Implementation plans for commit-relay based on open source AI best practices.

---

## Table of Contents

1. [Model Layer Improvements](#1-model-layer-improvements)
2. [Data Layer Improvements](#2-data-layer-improvements)
3. [Orchestration Layer Improvements](#3-orchestration-layer-improvements)
4. [Application Layer Improvements](#4-application-layer-improvements)
5. [Quick Wins](#5-quick-wins)

---

## 1. Model Layer Improvements

### 1.1 LLM Gateway Pattern (Multi-Provider Support)

**Goal**: Abstract LLM calls through a unified gateway supporting multiple providers with automatic failover.

**Priority**: High

#### Technical Approach

```
llm-mesh/
├── gateway/
│   ├── index.js                 # Main gateway entry point
│   ├── providers/
│   │   ├── base-provider.js     # Abstract provider interface
│   │   ├── anthropic.js         # Anthropic Claude adapter
│   │   ├── openai.js            # OpenAI GPT adapter
│   │   ├── ollama.js            # Local Ollama adapter
│   │   └── vllm.js              # vLLM server adapter
│   ├── router/
│   │   ├── model-router.js      # Route requests to optimal model
│   │   └── routing-rules.json   # Model selection rules
│   ├── middleware/
│   │   ├── token-counter.js     # Token counting middleware
│   │   ├── cost-tracker.js      # Cost calculation
│   │   ├── rate-limiter.js      # Provider rate limits
│   │   └── circuit-breaker.js   # Failover logic
│   └── config/
│       └── providers.json       # Provider configurations
```

#### Implementation Steps

1. **Create Base Provider Interface**
   ```javascript
   // llm-mesh/gateway/providers/base-provider.js
   class BaseProvider {
     async complete(messages, options) { throw new Error('Not implemented'); }
     async embed(text) { throw new Error('Not implemented'); }
     getTokenCount(text) { throw new Error('Not implemented'); }
     getCostPerToken() { throw new Error('Not implemented'); }
   }
   ```

2. **Implement Provider Adapters**
   - Anthropic: Use `@anthropic-ai/sdk`
   - OpenAI: Use `openai` npm package
   - Ollama: HTTP calls to `localhost:11434`
   - vLLM: OpenAI-compatible API endpoint

3. **Build Model Router**
   ```javascript
   // Routing rules example
   {
     "rules": [
       {
         "condition": { "task_type": "simple_routing", "token_estimate": "<1000" },
         "model": "claude-3-haiku-20240307",
         "provider": "anthropic"
       },
       {
         "condition": { "task_type": "complex_analysis" },
         "model": "claude-sonnet-4-20250514",
         "provider": "anthropic"
       },
       {
         "condition": { "data_sensitivity": "high" },
         "model": "llama3:8b",
         "provider": "ollama"
       }
     ]
   }
   ```

4. **Implement Circuit Breaker**
   - Track failure rates per provider
   - Auto-failover after 3 consecutive failures
   - Exponential backoff for retries
   - Health check endpoints

5. **Add Token Counting Middleware**
   - Use `tiktoken` for OpenAI models
   - Anthropic token counting via API
   - Pre-request token estimation
   - Post-request actual count

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `llm-mesh/gateway/index.js` | Create | Main gateway with unified API |
| `llm-mesh/gateway/providers/*.js` | Create | Provider adapters (4 files) |
| `llm-mesh/gateway/router/model-router.js` | Create | Model selection logic |
| `llm-mesh/gateway/middleware/*.js` | Create | Middleware stack (4 files) |
| `llm-mesh/config/providers.json` | Create | Provider configurations |
| `llm-mesh/moe-learning/evaluators/*.sh` | Modify | Use gateway instead of direct calls |
| `package.json` | Modify | Add dependencies |

#### Dependencies

```json
{
  "@anthropic-ai/sdk": "^0.24.0",
  "openai": "^4.47.0",
  "tiktoken": "^1.0.15",
  "opossum": "^8.1.3"  // Circuit breaker
}
```

#### Testing Strategy

1. Unit tests for each provider adapter
2. Integration tests with mock servers
3. Failover scenario testing
4. Load testing for rate limiting
5. Cost calculation accuracy tests

#### Success Metrics

- 99.9% gateway availability
- <100ms routing decision latency
- Automatic failover within 5 seconds
- Accurate cost tracking (±5%)

---

### 1.2 Task-Based Model Selection

**Goal**: Automatically select optimal model based on task complexity, sensitivity, and cost.

**Priority**: High

#### Technical Approach

Extend the MoE router to include model selection alongside master selection.

#### Implementation Steps

1. **Define Task Complexity Scoring**
   ```javascript
   // llm-mesh/gateway/router/complexity-scorer.js
   function scoreComplexity(task) {
     let score = 0;

     // Token estimate
     const tokens = estimateTokens(task.description);
     if (tokens > 4000) score += 3;
     else if (tokens > 1000) score += 2;
     else score += 1;

     // Task type multipliers
     const complexTypes = ['security_audit', 'architecture_review', 'multi_repo'];
     if (complexTypes.includes(task.type)) score += 2;

     // Keyword analysis
     const complexKeywords = ['comprehensive', 'analyze', 'evaluate', 'compare'];
     const matches = complexKeywords.filter(k => task.description.includes(k));
     score += matches.length;

     return score; // 1-10 scale
   }
   ```

2. **Create Model Tiers**
   ```json
   {
     "tiers": {
       "fast": {
         "complexity_max": 3,
         "models": ["claude-3-haiku-20240307", "gpt-3.5-turbo"],
         "use_cases": ["routing", "classification", "simple_extraction"]
       },
       "balanced": {
         "complexity_range": [4, 6],
         "models": ["claude-sonnet-4-20250514", "gpt-4-turbo"],
         "use_cases": ["code_generation", "analysis", "documentation"]
       },
       "powerful": {
         "complexity_min": 7,
         "models": ["claude-sonnet-4-20250514", "gpt-4o"],
         "use_cases": ["security_audit", "architecture", "complex_reasoning"]
       },
       "local": {
         "condition": "data_sensitivity=high",
         "models": ["llama3:70b", "codellama:34b"],
         "use_cases": ["sensitive_data", "air_gapped"]
       }
     }
   }
   ```

3. **Integrate with MoE Router**
   - Add `recommended_model` to routing decision
   - Log model selection reasoning
   - Track model performance per task type

4. **Add Sensitivity Detection**
   ```javascript
   function detectSensitivity(task) {
     const sensitivePatterns = [
       /credentials?/i, /password/i, /api.?key/i,
       /secret/i, /token/i, /private/i, /pii/i
     ];
     return sensitivePatterns.some(p => p.test(task.description));
   }
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `llm-mesh/gateway/router/complexity-scorer.js` | Create | Task complexity analysis |
| `llm-mesh/gateway/router/model-tiers.json` | Create | Model tier definitions |
| `llm-mesh/gateway/router/sensitivity-detector.js` | Create | Data sensitivity checks |
| `coordination/masters/coordinator/lib/moe-router.sh` | Modify | Add model recommendation |

#### Testing Strategy

1. Complexity scoring unit tests with sample tasks
2. Model selection integration tests
3. Sensitivity detection accuracy tests
4. A/B testing different model selections

---

### 1.3 Real Embeddings Integration

**Goal**: Replace mock hash-based embeddings with production embedding APIs.

**Priority**: High

#### Technical Approach

Create embedding provider abstraction similar to LLM gateway.

#### Implementation Steps

1. **Create Embedding Provider Interface**
   ```javascript
   // lib/rag/embeddings/base-embedder.js
   class BaseEmbedder {
     async embed(text) { throw new Error('Not implemented'); }
     async embedBatch(texts) { throw new Error('Not implemented'); }
     getDimensions() { throw new Error('Not implemented'); }
   }
   ```

2. **Implement Providers**
   ```javascript
   // lib/rag/embeddings/openai-embedder.js
   class OpenAIEmbedder extends BaseEmbedder {
     constructor(apiKey, model = 'text-embedding-3-small') {
       this.client = new OpenAI({ apiKey });
       this.model = model;
     }

     async embed(text) {
       const response = await this.client.embeddings.create({
         model: this.model,
         input: text
       });
       return response.data[0].embedding;
     }

     getDimensions() {
       return this.model === 'text-embedding-3-large' ? 3072 : 1536;
     }
   }
   ```

3. **Add Local Embedding Option (Ollama)**
   ```javascript
   // lib/rag/embeddings/ollama-embedder.js
   class OllamaEmbedder extends BaseEmbedder {
     async embed(text) {
       const response = await fetch('http://localhost:11434/api/embeddings', {
         method: 'POST',
         body: JSON.stringify({ model: 'nomic-embed-text', prompt: text })
       });
       const data = await response.json();
       return data.embedding;
     }
   }
   ```

4. **Update Vector Store**
   ```javascript
   // lib/rag/vector-store.js modifications
   class VectorStore {
     constructor(embedder) {
       this.embedder = embedder; // Inject embedding provider
     }

     async addDocument(collection, doc) {
       const embedding = await this.embedder.embed(doc.content);
       // Store with real embeddings
     }
   }
   ```

5. **Add Batch Processing**
   - Queue embedding requests
   - Batch API calls (max 100 per request for OpenAI)
   - Rate limiting per provider

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/rag/embeddings/base-embedder.js` | Create | Abstract interface |
| `lib/rag/embeddings/openai-embedder.js` | Create | OpenAI adapter |
| `lib/rag/embeddings/ollama-embedder.js` | Create | Local Ollama adapter |
| `lib/rag/embeddings/index.js` | Create | Factory function |
| `lib/rag/vector-store.js` | Modify | Use injected embedder |
| `lib/rag/context-manager.js` | Modify | Pass embedder to vector store |

#### Configuration

```json
// config/embeddings.json
{
  "provider": "openai",
  "openai": {
    "model": "text-embedding-3-small",
    "dimensions": 1536,
    "batch_size": 100
  },
  "ollama": {
    "model": "nomic-embed-text",
    "endpoint": "http://localhost:11434"
  }
}
```

#### Testing Strategy

1. Provider unit tests with mocked APIs
2. Embedding quality tests (semantic similarity)
3. Batch processing stress tests
4. Fallback scenario tests

---

### 1.4 Circuit Breaker for LLM Calls

**Goal**: Automatic failover and recovery for LLM API failures.

**Priority**: Medium

#### Technical Approach

Implement circuit breaker pattern using `opossum` library.

#### Implementation Steps

1. **Create Circuit Breaker Wrapper**
   ```javascript
   // llm-mesh/gateway/middleware/circuit-breaker.js
   const CircuitBreaker = require('opossum');

   function createProviderBreaker(provider, options = {}) {
     const breaker = new CircuitBreaker(
       (messages, opts) => provider.complete(messages, opts),
       {
         timeout: options.timeout || 30000,
         errorThresholdPercentage: options.errorThreshold || 50,
         resetTimeout: options.resetTimeout || 30000,
         volumeThreshold: options.volumeThreshold || 5
       }
     );

     breaker.on('open', () => {
       logger.warn(`Circuit OPEN for ${provider.name}`);
       metrics.increment('circuit_breaker.open', { provider: provider.name });
     });

     breaker.on('halfOpen', () => {
       logger.info(`Circuit HALF-OPEN for ${provider.name}`);
     });

     breaker.on('close', () => {
       logger.info(`Circuit CLOSED for ${provider.name}`);
     });

     return breaker;
   }
   ```

2. **Implement Failover Chain**
   ```javascript
   // llm-mesh/gateway/middleware/failover.js
   class FailoverChain {
     constructor(providers) {
       this.breakers = providers.map(p => ({
         provider: p,
         breaker: createProviderBreaker(p)
       }));
     }

     async execute(messages, options) {
       for (const { provider, breaker } of this.breakers) {
         try {
           if (breaker.opened) continue;
           return await breaker.fire(messages, options);
         } catch (error) {
           logger.warn(`Provider ${provider.name} failed: ${error.message}`);
           continue;
         }
       }
       throw new Error('All providers failed');
     }
   }
   ```

3. **Add Health Checks**
   ```javascript
   // Periodic health check for each provider
   async function healthCheck(provider) {
     try {
       await provider.complete([
         { role: 'user', content: 'ping' }
       ], { max_tokens: 1 });
       return true;
     } catch {
       return false;
     }
   }
   ```

4. **Dashboard Integration**
   - Circuit state visualization
   - Failure rate graphs
   - Provider health status

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `llm-mesh/gateway/middleware/circuit-breaker.js` | Create | Breaker implementation |
| `llm-mesh/gateway/middleware/failover.js` | Create | Failover chain logic |
| `llm-mesh/gateway/middleware/health-check.js` | Create | Provider health monitoring |
| `api-server/routes/llm-health.js` | Create | Health status API |

---

### 1.5 Token Budget Enforcement

**Goal**: Track and enforce token limits per task and session with cost tracking.

**Priority**: Medium

#### Technical Approach

Middleware that tracks tokens and enforces budgets at multiple levels.

#### Implementation Steps

1. **Create Token Counter**
   ```javascript
   // llm-mesh/gateway/middleware/token-counter.js
   const { encoding_for_model } = require('tiktoken');

   class TokenCounter {
     constructor() {
       this.encoders = new Map();
     }

     count(text, model = 'gpt-4') {
       if (!this.encoders.has(model)) {
         this.encoders.set(model, encoding_for_model(model));
       }
       return this.encoders.get(model).encode(text).length;
     }

     countMessages(messages, model) {
       return messages.reduce((sum, m) => {
         return sum + this.count(m.content, model) + 4; // Message overhead
       }, 3); // Conversation overhead
     }
   }
   ```

2. **Implement Budget Manager**
   ```javascript
   // llm-mesh/gateway/middleware/budget-manager.js
   class BudgetManager {
     constructor(config) {
       this.budgets = {
         task: config.task_budget || 10000,
         session: config.session_budget || 100000,
         daily: config.daily_budget || 1000000
       };
       this.usage = new Map();
     }

     async checkBudget(taskId, estimatedTokens) {
       const taskUsage = this.getUsage(taskId);

       if (taskUsage + estimatedTokens > this.budgets.task) {
         throw new BudgetExceededError('Task budget exceeded', {
           used: taskUsage,
           limit: this.budgets.task,
           requested: estimatedTokens
         });
       }

       // Check session and daily budgets similarly
     }

     recordUsage(taskId, tokens, cost) {
       // Update usage tracking
       // Persist to metrics file
     }
   }
   ```

3. **Cost Calculation**
   ```javascript
   // llm-mesh/gateway/middleware/cost-tracker.js
   const PRICING = {
     'claude-3-haiku-20240307': { input: 0.25, output: 1.25 },
     'claude-sonnet-4-20250514': { input: 3.0, output: 15.0 },
     'gpt-4-turbo': { input: 10.0, output: 30.0 },
     'gpt-3.5-turbo': { input: 0.5, output: 1.5 }
   };

   function calculateCost(model, inputTokens, outputTokens) {
     const pricing = PRICING[model];
     return (
       (inputTokens / 1000000) * pricing.input +
       (outputTokens / 1000000) * pricing.output
     );
   }
   ```

4. **Persist Cost Metrics**
   ```javascript
   // Write to coordination/metrics/llm-costs.jsonl
   {
     "timestamp": "2024-01-15T10:30:00Z",
     "task_id": "task-001",
     "master": "development-master",
     "model": "claude-sonnet-4-20250514",
     "input_tokens": 1500,
     "output_tokens": 800,
     "cost_usd": 0.0165,
     "budget_remaining": 8500
   }
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `llm-mesh/gateway/middleware/token-counter.js` | Create | Token counting |
| `llm-mesh/gateway/middleware/budget-manager.js` | Create | Budget enforcement |
| `llm-mesh/gateway/middleware/cost-tracker.js` | Create | Cost calculation |
| `coordination/metrics/llm-costs.jsonl` | Create | Cost history |
| `coordination/config/token-budgets.json` | Create | Budget configuration |

#### Configuration

```json
// coordination/config/token-budgets.json
{
  "budgets": {
    "task": {
      "default": 10000,
      "security_audit": 50000,
      "simple_fix": 5000
    },
    "session": 100000,
    "daily": 1000000,
    "monthly": 10000000
  },
  "alerts": {
    "warn_threshold": 0.8,
    "critical_threshold": 0.95
  }
}
```

---

## 2. Data Layer Improvements

### 2.1 Production Vector Store Integration

**Goal**: Replace file-based vector DB with scalable production solution.

**Priority**: High

#### Technical Approach

Integrate Weaviate or Qdrant as the primary vector store with file-based fallback.

#### Implementation Steps

1. **Create Vector Store Abstraction**
   ```javascript
   // lib/rag/stores/base-store.js
   class BaseVectorStore {
     async createCollection(name, config) { throw new Error('Not implemented'); }
     async insert(collection, documents) { throw new Error('Not implemented'); }
     async search(collection, vector, limit) { throw new Error('Not implemented'); }
     async delete(collection, ids) { throw new Error('Not implemented'); }
   }
   ```

2. **Implement Weaviate Adapter**
   ```javascript
   // lib/rag/stores/weaviate-store.js
   const weaviate = require('weaviate-ts-client');

   class WeaviateStore extends BaseVectorStore {
     constructor(config) {
       this.client = weaviate.client({
         scheme: config.scheme || 'http',
         host: config.host || 'localhost:8080'
       });
     }

     async createCollection(name, config) {
       await this.client.schema.classCreator()
         .withClass({
           class: name,
           vectorizer: 'none', // We provide vectors
           properties: config.properties
         })
         .do();
     }

     async search(collection, vector, limit = 10) {
       const result = await this.client.graphql
         .get()
         .withClassName(collection)
         .withNearVector({ vector })
         .withLimit(limit)
         .withFields('content metadata _additional { distance }')
         .do();

       return result.data.Get[collection];
     }
   }
   ```

3. **Implement Qdrant Adapter**
   ```javascript
   // lib/rag/stores/qdrant-store.js
   const { QdrantClient } = require('@qdrant/js-client-rest');

   class QdrantStore extends BaseVectorStore {
     constructor(config) {
       this.client = new QdrantClient({
         url: config.url || 'http://localhost:6333'
       });
     }

     async createCollection(name, config) {
       await this.client.createCollection(name, {
         vectors: {
           size: config.dimensions || 1536,
           distance: 'Cosine'
         }
       });
     }

     async search(collection, vector, limit = 10) {
       const results = await this.client.search(collection, {
         vector,
         limit,
         with_payload: true
       });
       return results;
     }
   }
   ```

4. **Migration Script**
   ```javascript
   // scripts/migrate-vector-store.js
   async function migrate(source, target) {
     const collections = await source.listCollections();

     for (const collection of collections) {
       console.log(`Migrating ${collection}...`);
       await target.createCollection(collection, source.getConfig(collection));

       const documents = await source.getAll(collection);
       const batches = chunk(documents, 100);

       for (const batch of batches) {
         await target.insert(collection, batch);
       }
     }
   }
   ```

5. **Docker Compose for Development**
   ```yaml
   # docker-compose.yml
   services:
     weaviate:
       image: semitechnologies/weaviate:1.24.1
       ports:
         - "8080:8080"
       environment:
         QUERY_DEFAULTS_LIMIT: 25
         AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED: 'true'
         PERSISTENCE_DATA_PATH: '/var/lib/weaviate'
       volumes:
         - weaviate_data:/var/lib/weaviate

     qdrant:
       image: qdrant/qdrant:v1.8.1
       ports:
         - "6333:6333"
       volumes:
         - qdrant_data:/qdrant/storage

   volumes:
     weaviate_data:
     qdrant_data:
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/rag/stores/base-store.js` | Create | Abstract interface |
| `lib/rag/stores/weaviate-store.js` | Create | Weaviate adapter |
| `lib/rag/stores/qdrant-store.js` | Create | Qdrant adapter |
| `lib/rag/stores/file-store.js` | Rename | Current implementation as fallback |
| `lib/rag/stores/index.js` | Create | Store factory |
| `scripts/migrate-vector-store.js` | Create | Migration tool |
| `docker-compose.yml` | Create | Dev infrastructure |
| `lib/rag/vector-store.js` | Modify | Use store abstraction |

#### Configuration

```json
// config/vector-store.json
{
  "provider": "weaviate",
  "weaviate": {
    "host": "localhost:8080",
    "scheme": "http"
  },
  "qdrant": {
    "url": "http://localhost:6333"
  },
  "file": {
    "path": "coordination/vector-db"
  },
  "collections": {
    "code": { "dimensions": 1536 },
    "documentation": { "dimensions": 1536 },
    "decisions": { "dimensions": 1536 },
    "patterns": { "dimensions": 1536 },
    "tasks": { "dimensions": 1536 }
  }
}
```

#### Testing Strategy

1. Unit tests for each store adapter
2. Integration tests with Docker containers
3. Migration script validation
4. Performance benchmarks (search latency, throughput)
5. Data consistency tests

---

### 2.2 Hybrid Search (Keyword + Semantic)

**Goal**: Combine BM25 keyword search with vector semantic search for better retrieval.

**Priority**: Medium

#### Technical Approach

Implement fusion ranking that combines keyword and semantic search results.

#### Implementation Steps

1. **Add Keyword Search Engine**
   ```javascript
   // lib/rag/search/keyword-search.js
   const MiniSearch = require('minisearch');

   class KeywordSearch {
     constructor() {
       this.index = new MiniSearch({
         fields: ['content', 'title', 'tags'],
         storeFields: ['id', 'content', 'metadata'],
         searchOptions: {
           boost: { title: 2 },
           fuzzy: 0.2
         }
       });
     }

     addDocuments(documents) {
       this.index.addAll(documents);
     }

     search(query, limit = 10) {
       return this.index.search(query, { limit });
     }
   }
   ```

2. **Implement Reciprocal Rank Fusion**
   ```javascript
   // lib/rag/search/fusion.js
   function reciprocalRankFusion(results, k = 60) {
     const scores = new Map();

     for (const resultSet of results) {
       resultSet.forEach((doc, rank) => {
         const id = doc.id;
         const rrf = 1 / (k + rank + 1);
         scores.set(id, (scores.get(id) || 0) + rrf);
       });
     }

     return Array.from(scores.entries())
       .sort((a, b) => b[1] - a[1])
       .map(([id, score]) => ({ id, score }));
   }
   ```

3. **Create Hybrid Search Interface**
   ```javascript
   // lib/rag/search/hybrid-search.js
   class HybridSearch {
     constructor(vectorStore, keywordSearch, embedder) {
       this.vectorStore = vectorStore;
       this.keywordSearch = keywordSearch;
       this.embedder = embedder;
     }

     async search(collection, query, options = {}) {
       const { limit = 10, alpha = 0.5 } = options;

       // Parallel search
       const [semanticResults, keywordResults] = await Promise.all([
         this.semanticSearch(collection, query, limit * 2),
         this.keywordSearch.search(query, limit * 2)
       ]);

       // Fusion with configurable weighting
       const fused = this.weightedFusion(
         semanticResults,
         keywordResults,
         alpha
       );

       return fused.slice(0, limit);
     }

     weightedFusion(semantic, keyword, alpha) {
       // alpha: 0 = keyword only, 1 = semantic only
       const scores = new Map();

       semantic.forEach((doc, i) => {
         const score = (1 - i / semantic.length) * alpha;
         scores.set(doc.id, (scores.get(doc.id) || 0) + score);
       });

       keyword.forEach((doc, i) => {
         const score = (1 - i / keyword.length) * (1 - alpha);
         scores.set(doc.id, (scores.get(doc.id) || 0) + score);
       });

       return Array.from(scores.entries())
         .sort((a, b) => b[1] - a[1])
         .map(([id, score]) => ({ id, score }));
     }
   }
   ```

4. **Update Context Manager**
   ```javascript
   // lib/rag/context-manager.js modifications
   async getContext(query, options) {
     const results = await this.hybridSearch.search(
       'tasks',
       query,
       { alpha: options.semantic_weight || 0.7 }
     );
     // Rest of context building...
   }
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/rag/search/keyword-search.js` | Create | BM25 keyword search |
| `lib/rag/search/fusion.js` | Create | RRF algorithm |
| `lib/rag/search/hybrid-search.js` | Create | Combined search |
| `lib/rag/context-manager.js` | Modify | Use hybrid search |
| `package.json` | Modify | Add minisearch |

#### Testing Strategy

1. Retrieval quality tests with known relevant documents
2. Compare hybrid vs pure semantic vs pure keyword
3. Tune alpha parameter for different query types
4. Benchmark search latency

---

### 2.3 Repository Connectors

**Goal**: Auto-ingest knowledge from GitHub, docs, Confluence, Slack.

**Priority**: Medium

#### Technical Approach

Create a connector framework with scheduled ingestion.

#### Implementation Steps

1. **Create Connector Interface**
   ```javascript
   // lib/rag/connectors/base-connector.js
   class BaseConnector {
     async connect() { throw new Error('Not implemented'); }
     async fetch(options) { throw new Error('Not implemented'); }
     async transform(data) { throw new Error('Not implemented'); }
   }
   ```

2. **Implement GitHub Connector**
   ```javascript
   // lib/rag/connectors/github-connector.js
   const { Octokit } = require('@octokit/rest');

   class GitHubConnector extends BaseConnector {
     constructor(config) {
       this.octokit = new Octokit({ auth: config.token });
       this.owner = config.owner;
       this.repo = config.repo;
     }

     async fetch(options = {}) {
       const documents = [];

       // Fetch README
       const readme = await this.octokit.repos.getReadme({
         owner: this.owner,
         repo: this.repo
       });
       documents.push({
         type: 'readme',
         content: Buffer.from(readme.data.content, 'base64').toString(),
         path: readme.data.path
       });

       // Fetch issues/PRs
       if (options.includeIssues) {
         const issues = await this.octokit.issues.listForRepo({
           owner: this.owner,
           repo: this.repo,
           state: 'all',
           per_page: 100
         });
         documents.push(...issues.data.map(this.transformIssue));
       }

       // Fetch code files
       if (options.includeCode) {
         const tree = await this.fetchTree();
         documents.push(...await this.fetchFiles(tree, options.patterns));
       }

       return documents;
     }
   }
   ```

3. **Implement Confluence Connector**
   ```javascript
   // lib/rag/connectors/confluence-connector.js
   class ConfluenceConnector extends BaseConnector {
     async fetch(options = {}) {
       const response = await fetch(
         `${this.baseUrl}/wiki/rest/api/content`,
         {
           headers: {
             'Authorization': `Basic ${this.auth}`,
             'Content-Type': 'application/json'
           },
           body: JSON.stringify({
             spaceKey: options.space,
             expand: 'body.storage'
           })
         }
       );

       const data = await response.json();
       return data.results.map(page => ({
         id: page.id,
         title: page.title,
         content: this.htmlToText(page.body.storage.value),
         url: `${this.baseUrl}${page._links.webui}`
       }));
     }
   }
   ```

4. **Create Ingestion Scheduler**
   ```javascript
   // lib/rag/connectors/ingestion-scheduler.js
   class IngestionScheduler {
     constructor(connectors, vectorStore, embedder) {
       this.connectors = connectors;
       this.vectorStore = vectorStore;
       this.embedder = embedder;
     }

     async runIngestion(connectorName) {
       const connector = this.connectors.get(connectorName);
       const documents = await connector.fetch();

       for (const doc of documents) {
         const embedding = await this.embedder.embed(doc.content);
         await this.vectorStore.insert('documentation', {
           ...doc,
           embedding,
           source: connectorName,
           ingested_at: new Date().toISOString()
         });
       }

       logger.info(`Ingested ${documents.length} docs from ${connectorName}`);
     }

     schedule(connectorName, cron) {
       // Use node-cron for scheduling
     }
   }
   ```

5. **Create Ingestion Daemon**
   ```bash
   # scripts/daemons/ingestion-daemon.sh
   #!/bin/bash
   # Run scheduled ingestion jobs
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/rag/connectors/base-connector.js` | Create | Abstract interface |
| `lib/rag/connectors/github-connector.js` | Create | GitHub adapter |
| `lib/rag/connectors/confluence-connector.js` | Create | Confluence adapter |
| `lib/rag/connectors/slack-connector.js` | Create | Slack adapter |
| `lib/rag/connectors/ingestion-scheduler.js` | Create | Scheduling logic |
| `scripts/daemons/ingestion-daemon.sh` | Create | Daemon script |
| `coordination/config/connectors.json` | Create | Connector configs |

#### Configuration

```json
// coordination/config/connectors.json
{
  "github": {
    "enabled": true,
    "token": "${GITHUB_TOKEN}",
    "repos": [
      { "owner": "org", "repo": "main-app", "patterns": ["*.md", "src/**/*.ts"] }
    ],
    "schedule": "0 */6 * * *"
  },
  "confluence": {
    "enabled": false,
    "baseUrl": "https://company.atlassian.net",
    "spaces": ["DEV", "OPS"],
    "schedule": "0 0 * * *"
  }
}
```

---

### 2.4 Document Conversion (PDF/Markdown)

**Goal**: Convert unstructured documents to indexed knowledge.

**Priority**: Low

#### Implementation Steps

1. **PDF Parser**
   ```javascript
   // lib/rag/parsers/pdf-parser.js
   const pdf = require('pdf-parse');

   async function parsePDF(buffer) {
     const data = await pdf(buffer);
     return {
       text: data.text,
       pages: data.numpages,
       metadata: data.info
     };
   }
   ```

2. **Markdown Parser with Chunking**
   ```javascript
   // lib/rag/parsers/markdown-parser.js
   const marked = require('marked');

   function parseMarkdown(content) {
     const tokens = marked.lexer(content);
     const chunks = [];
     let currentChunk = { heading: '', content: '' };

     for (const token of tokens) {
       if (token.type === 'heading') {
         if (currentChunk.content) chunks.push(currentChunk);
         currentChunk = { heading: token.text, content: '' };
       } else {
         currentChunk.content += token.raw;
       }
     }

     if (currentChunk.content) chunks.push(currentChunk);
     return chunks;
   }
   ```

3. **Chunking Strategy**
   ```javascript
   // lib/rag/parsers/chunker.js
   function chunkText(text, options = {}) {
     const { chunkSize = 1000, overlap = 200 } = options;
     const chunks = [];

     let start = 0;
     while (start < text.length) {
       const end = Math.min(start + chunkSize, text.length);
       chunks.push(text.slice(start, end));
       start = end - overlap;
     }

     return chunks;
   }
   ```

#### Files to Create

| File | Description |
|------|-------------|
| `lib/rag/parsers/pdf-parser.js` | PDF extraction |
| `lib/rag/parsers/markdown-parser.js` | Markdown parsing |
| `lib/rag/parsers/chunker.js` | Text chunking |
| `lib/rag/parsers/index.js` | Parser factory |

---

### 2.5 Knowledge Freshness Management

**Goal**: Ensure stale patterns get refreshed with TTL-based re-indexing.

**Priority**: Low

#### Implementation Steps

1. **Add TTL Metadata**
   ```javascript
   // When storing documents
   {
     id: 'doc-123',
     content: '...',
     embedding: [...],
     metadata: {
       created_at: '2024-01-01T00:00:00Z',
       updated_at: '2024-01-15T00:00:00Z',
       ttl_days: 30,
       expires_at: '2024-02-14T00:00:00Z',
       source: 'github',
       freshness_score: 0.95
     }
   }
   ```

2. **Freshness Scoring**
   ```javascript
   // lib/rag/freshness/scorer.js
   function calculateFreshness(doc) {
     const age = Date.now() - new Date(doc.updated_at).getTime();
     const maxAge = doc.ttl_days * 24 * 60 * 60 * 1000;
     return Math.max(0, 1 - (age / maxAge));
   }
   ```

3. **Re-indexing Job**
   ```javascript
   // lib/rag/freshness/reindexer.js
   async function reindexStale(threshold = 0.3) {
     const stale = await vectorStore.query({
       filter: { freshness_score: { $lt: threshold } }
     });

     for (const doc of stale) {
       const freshContent = await fetchFresh(doc.source, doc.id);
       if (freshContent !== doc.content) {
         const embedding = await embedder.embed(freshContent);
         await vectorStore.update(doc.id, {
           content: freshContent,
           embedding,
           updated_at: new Date().toISOString(),
           freshness_score: 1.0
         });
       }
     }
   }
   ```

---

## 3. Orchestration Layer Improvements

### 3.1 Declarative DAG Workflows

**Goal**: Define workflows as YAML/JSON DAGs instead of imperative code.

**Priority**: Medium

#### Technical Approach

Create a workflow engine that parses declarative definitions and executes them.

#### Implementation Steps

1. **Define Workflow Schema**
   ```yaml
   # coordination/workflows/security-audit.yaml
   name: security-audit
   version: 1.0

   triggers:
     - type: schedule
       cron: "0 0 * * 0"
     - type: event
       pattern: "new_repository"

   inputs:
     repository:
       type: string
       required: true
     scan_depth:
       type: string
       default: "full"

   steps:
     - id: clone
       master: development
       action: clone_repository
       inputs:
         url: "{{ inputs.repository }}"
       outputs:
         - repo_path

     - id: dependency_scan
       master: security
       action: scan_dependencies
       inputs:
         path: "{{ steps.clone.outputs.repo_path }}"
       depends_on: [clone]
       outputs:
         - vulnerabilities

     - id: code_scan
       master: security
       action: scan_code
       inputs:
         path: "{{ steps.clone.outputs.repo_path }}"
       depends_on: [clone]
       parallel_with: [dependency_scan]
       outputs:
         - findings

     - id: generate_report
       master: inventory
       action: create_report
       inputs:
         vulnerabilities: "{{ steps.dependency_scan.outputs.vulnerabilities }}"
         findings: "{{ steps.code_scan.outputs.findings }}"
       depends_on: [dependency_scan, code_scan]
       outputs:
         - report_url

   on_failure:
     - notify:
         channel: "#security-alerts"
         message: "Audit failed for {{ inputs.repository }}"
   ```

2. **Create Workflow Engine**
   ```javascript
   // lib/orchestration/workflow-engine.js
   class WorkflowEngine {
     constructor(masters, eventBus) {
       this.masters = masters;
       this.eventBus = eventBus;
       this.workflows = new Map();
     }

     async loadWorkflow(path) {
       const definition = yaml.load(await fs.readFile(path));
       this.validateWorkflow(definition);
       this.workflows.set(definition.name, definition);
     }

     async execute(workflowName, inputs) {
       const workflow = this.workflows.get(workflowName);
       const execution = new WorkflowExecution(workflow, inputs);

       // Build dependency graph
       const dag = this.buildDAG(workflow.steps);

       // Execute in topological order
       for (const step of this.topologicalSort(dag)) {
         if (this.canExecute(step, execution)) {
           await this.executeStep(step, execution);
         }
       }

       return execution.outputs;
     }

     buildDAG(steps) {
       const graph = new Map();
       for (const step of steps) {
         graph.set(step.id, {
           step,
           dependencies: step.depends_on || [],
           dependents: []
         });
       }
       // Build reverse edges
       for (const [id, node] of graph) {
         for (const dep of node.dependencies) {
           graph.get(dep).dependents.push(id);
         }
       }
       return graph;
     }
   }
   ```

3. **Step Executor**
   ```javascript
   // lib/orchestration/step-executor.js
   class StepExecutor {
     async executeStep(step, context) {
       const master = this.masters.get(step.master);
       const resolvedInputs = this.resolveInputs(step.inputs, context);

       const result = await master.execute({
         action: step.action,
         inputs: resolvedInputs,
         timeout: step.timeout || 300000
       });

       context.setOutputs(step.id, result.outputs);
       return result;
     }

     resolveInputs(inputs, context) {
       const resolved = {};
       for (const [key, value] of Object.entries(inputs)) {
         if (typeof value === 'string' && value.includes('{{')) {
           resolved[key] = this.interpolate(value, context);
         } else {
           resolved[key] = value;
         }
       }
       return resolved;
     }
   }
   ```

4. **Parallel Execution Support**
   ```javascript
   async executeParallel(steps, execution) {
     const promises = steps.map(step =>
       this.executeStep(step, execution)
     );
     return Promise.all(promises);
   }
   ```

5. **Workflow Visualization API**
   ```javascript
   // api-server/routes/workflows.js
   router.get('/:name/graph', async (req, res) => {
     const workflow = engine.workflows.get(req.params.name);
     const graph = engine.buildDAG(workflow.steps);

     // Return in format suitable for visualization
     res.json({
       nodes: Array.from(graph.values()).map(n => ({
         id: n.step.id,
         master: n.step.master,
         action: n.step.action
       })),
       edges: Array.from(graph.entries()).flatMap(([id, node]) =>
         node.dependencies.map(dep => ({ from: dep, to: id }))
       )
     });
   });
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/orchestration/workflow-engine.js` | Create | Main engine |
| `lib/orchestration/step-executor.js` | Create | Step execution |
| `lib/orchestration/workflow-schema.json` | Create | JSON schema for validation |
| `coordination/workflows/*.yaml` | Create | Workflow definitions |
| `api-server/routes/workflows.js` | Create | Workflow API |
| `scripts/daemons/workflow-daemon.sh` | Create | Workflow scheduler |

#### Testing Strategy

1. Schema validation tests
2. DAG cycle detection tests
3. Parallel execution tests
4. Failure handling tests
5. Variable interpolation tests

---

### 3.2 Quality Review Loops

**Goal**: Agent self-review before task completion to improve output quality.

**Priority**: High

#### Technical Approach

Add configurable review cycles to task execution with confidence thresholds.

#### Implementation Steps

1. **Define Review Configuration**
   ```json
   // coordination/config/review-policy.json
   {
     "enabled": true,
     "default_cycles": 1,
     "max_cycles": 3,
     "confidence_threshold": 0.85,
     "auto_approve_threshold": 0.95,
     "review_prompts": {
       "code": "Review this code for correctness, security, and style...",
       "security": "Review this security assessment for completeness...",
       "documentation": "Review this documentation for clarity..."
     },
     "task_specific": {
       "security_audit": { "min_cycles": 2 },
       "production_deploy": { "require_human": true }
     }
   }
   ```

2. **Create Review Executor**
   ```javascript
   // lib/orchestration/review-executor.js
   class ReviewExecutor {
     constructor(llmGateway, config) {
       this.llm = llmGateway;
       this.config = config;
     }

     async review(task, output) {
       const prompt = this.buildReviewPrompt(task, output);

       const review = await this.llm.complete([
         { role: 'system', content: this.config.review_prompts[task.type] },
         { role: 'user', content: prompt }
       ]);

       return {
         approved: review.confidence >= this.config.confidence_threshold,
         confidence: review.confidence,
         feedback: review.feedback,
         suggestions: review.suggestions
       };
     }

     buildReviewPrompt(task, output) {
       return `
         Task: ${task.description}
         Output:
         ${JSON.stringify(output, null, 2)}

         Review criteria:
         1. Does this fully address the task?
         2. Are there any errors or issues?
         3. What improvements could be made?

         Provide confidence score (0-1) and detailed feedback.
       `;
     }
   }
   ```

3. **Integrate with Task Execution**
   ```javascript
   // lib/orchestration/task-executor.js modifications
   async executeWithReview(task) {
     let output = await this.execute(task);
     let cycles = 0;
     const maxCycles = this.getMaxCycles(task);

     while (cycles < maxCycles) {
       const review = await this.reviewExecutor.review(task, output);

       this.logReview(task.id, cycles, review);

       if (review.approved || review.confidence >= this.config.auto_approve_threshold) {
         return { output, review, cycles };
       }

       // Refine based on feedback
       output = await this.refine(task, output, review.feedback);
       cycles++;
     }

     // Max cycles reached, escalate if needed
     if (this.shouldEscalate(task)) {
       await this.escalateToHuman(task, output);
     }

     return { output, review: { approved: false }, cycles };
   }
   ```

4. **Track Review Outcomes**
   ```javascript
   // coordination/metrics/review-history.jsonl
   {
     "timestamp": "2024-01-15T10:30:00Z",
     "task_id": "task-001",
     "task_type": "code_generation",
     "cycles": 2,
     "initial_confidence": 0.72,
     "final_confidence": 0.91,
     "approved": true,
     "improvements": ["Added error handling", "Fixed edge case"]
   }
   ```

5. **Learning from Reviews**
   ```javascript
   // Analyze review patterns to improve initial outputs
   async analyzeReviewPatterns() {
     const history = await this.loadReviewHistory();

     const patterns = history
       .filter(r => r.cycles > 1)
       .reduce((acc, r) => {
         const key = r.task_type;
         if (!acc[key]) acc[key] = [];
         acc[key].push(r.improvements);
         return acc;
       }, {});

     // Feed patterns back to improve prompts
     return patterns;
   }
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/orchestration/review-executor.js` | Create | Review logic |
| `coordination/config/review-policy.json` | Create | Review configuration |
| `coordination/metrics/review-history.jsonl` | Create | Review tracking |
| `lib/orchestration/task-executor.js` | Modify | Add review cycles |
| `scripts/spawn-worker.sh` | Modify | Pass review config |

---

### 3.3 Conditional Branching

**Goal**: If/else paths based on task outcomes in workflows.

**Priority**: Medium

#### Implementation Steps

1. **Extend Workflow Schema**
   ```yaml
   steps:
     - id: check_severity
       action: classify_severity
       outputs:
         - severity_level

     - id: quick_fix
       action: apply_patch
       condition: "{{ steps.check_severity.outputs.severity_level == 'low' }}"
       depends_on: [check_severity]

     - id: full_remediation
       action: comprehensive_fix
       condition: "{{ steps.check_severity.outputs.severity_level in ['high', 'critical'] }}"
       depends_on: [check_severity]

     - id: notify
       action: send_alert
       condition: "{{ steps.check_severity.outputs.severity_level == 'critical' }}"
       depends_on: [check_severity]
   ```

2. **Condition Evaluator**
   ```javascript
   // lib/orchestration/condition-evaluator.js
   class ConditionEvaluator {
     evaluate(condition, context) {
       // Parse and evaluate condition expression
       const resolved = this.resolveVariables(condition, context);
       return this.safeEval(resolved);
     }

     resolveVariables(expr, context) {
       return expr.replace(/\{\{\s*(.+?)\s*\}\}/g, (_, path) => {
         return this.getByPath(context, path);
       });
     }

     safeEval(expr) {
       // Use a safe expression evaluator (not eval!)
       return new SafeExpressionParser().parse(expr).evaluate();
     }
   }
   ```

3. **Update Workflow Engine**
   ```javascript
   async executeStep(step, execution) {
     if (step.condition) {
       const shouldExecute = this.conditionEvaluator.evaluate(
         step.condition,
         execution.context
       );

       if (!shouldExecute) {
         execution.markSkipped(step.id, 'condition_not_met');
         return null;
       }
     }

     return await this.stepExecutor.execute(step, execution);
   }
   ```

---

### 3.4 Timeout Management with SLAs

**Goal**: Per-task SLAs with escalation on breach.

**Priority**: Medium

#### Implementation Steps

1. **Define SLA Configuration**
   ```json
   // coordination/config/sla-policy.json
   {
     "defaults": {
       "warning_threshold": 0.8,
       "critical_threshold": 0.95
     },
     "task_types": {
       "security_scan": {
         "timeout_ms": 300000,
         "escalation": "security-lead"
       },
       "code_generation": {
         "timeout_ms": 600000,
         "escalation": "dev-team"
       },
       "documentation": {
         "timeout_ms": 180000,
         "escalation": null
       }
     },
     "escalation_channels": {
       "security-lead": { "type": "slack", "channel": "#security-alerts" },
       "dev-team": { "type": "slack", "channel": "#dev-alerts" }
     }
   }
   ```

2. **SLA Monitor**
   ```javascript
   // lib/orchestration/sla-monitor.js
   class SLAMonitor {
     constructor(config, notifier) {
       this.config = config;
       this.notifier = notifier;
       this.activeTimers = new Map();
     }

     startMonitoring(task) {
       const sla = this.getSLA(task.type);

       const warningTimer = setTimeout(() => {
         this.onWarning(task);
       }, sla.timeout_ms * this.config.defaults.warning_threshold);

       const criticalTimer = setTimeout(() => {
         this.onCritical(task);
       }, sla.timeout_ms * this.config.defaults.critical_threshold);

       const timeoutTimer = setTimeout(() => {
         this.onTimeout(task);
       }, sla.timeout_ms);

       this.activeTimers.set(task.id, {
         warningTimer,
         criticalTimer,
         timeoutTimer,
         startTime: Date.now()
       });
     }

     onTimeout(task) {
       const sla = this.getSLA(task.type);

       if (sla.escalation) {
         this.notifier.escalate(sla.escalation, {
           task,
           reason: 'SLA timeout',
           elapsed: Date.now() - this.activeTimers.get(task.id).startTime
         });
       }

       // Cancel the task
       this.cancelTask(task.id);
     }
   }
   ```

3. **Dashboard Integration**
   - Real-time SLA status for active tasks
   - SLA breach history
   - Average completion time vs SLA

---

### 3.5 Backpressure / Rate Limiting at Orchestration Level

**Goal**: Prevent queue flooding and manage system load.

**Priority**: Low

#### Implementation Steps

1. **Queue Manager with Backpressure**
   ```javascript
   // lib/orchestration/queue-manager.js
   class QueueManager {
     constructor(config) {
       this.maxQueueSize = config.max_queue_size || 1000;
       this.maxConcurrent = config.max_concurrent || 50;
       this.queue = [];
       this.active = new Set();
     }

     async enqueue(task) {
       if (this.queue.length >= this.maxQueueSize) {
         throw new BackpressureError('Queue full', {
           queueSize: this.queue.length,
           maxSize: this.maxQueueSize
         });
       }

       // Apply priority scoring
       const priority = this.calculatePriority(task);
       this.queue.push({ task, priority, enqueued: Date.now() });
       this.queue.sort((a, b) => b.priority - a.priority);

       this.processQueue();
     }

     processQueue() {
       while (
         this.queue.length > 0 &&
         this.active.size < this.maxConcurrent
       ) {
         const { task } = this.queue.shift();
         this.active.add(task.id);
         this.execute(task).finally(() => {
           this.active.delete(task.id);
           this.processQueue();
         });
       }
     }
   }
   ```

2. **Rate Limiting per Master**
   ```javascript
   // Limit concurrent tasks per master
   const masterLimits = {
     'security-master': 5,
     'development-master': 10,
     'inventory-master': 20
   };
   ```

---

## 4. Application Layer Improvements

### 4.1 DAG Workflow Visualization

**Goal**: Visual representation of task decomposition and workflow execution.

**Priority**: Medium

#### Technical Approach

Use React Flow or similar library to render workflow DAGs.

#### Implementation Steps

1. **Install Visualization Library**
   ```bash
   cd eui-dashboard
   npm install reactflow dagre
   ```

2. **Create DAG Component**
   ```typescript
   // eui-dashboard/src/components/WorkflowDAG.tsx
   import ReactFlow, {
     Node,
     Edge,
     Position,
     MarkerType
   } from 'reactflow';
   import dagre from 'dagre';

   interface WorkflowDAGProps {
     workflow: Workflow;
     execution?: WorkflowExecution;
   }

   export function WorkflowDAG({ workflow, execution }: WorkflowDAGProps) {
     const { nodes, edges } = useMemo(() => {
       return layoutGraph(workflow, execution);
     }, [workflow, execution]);

     return (
       <ReactFlow
         nodes={nodes}
         edges={edges}
         fitView
         nodeTypes={customNodeTypes}
       />
     );
   }

   function layoutGraph(workflow: Workflow, execution?: WorkflowExecution) {
     const g = new dagre.graphlib.Graph();
     g.setGraph({ rankdir: 'TB', nodesep: 50, ranksep: 100 });
     g.setDefaultEdgeLabel(() => ({}));

     // Add nodes
     workflow.steps.forEach(step => {
       const status = execution?.stepStatus[step.id] || 'pending';
       g.setNode(step.id, {
         label: step.id,
         width: 150,
         height: 50,
         data: { step, status }
       });
     });

     // Add edges
     workflow.steps.forEach(step => {
       (step.depends_on || []).forEach(dep => {
         g.setEdge(dep, step.id);
       });
     });

     dagre.layout(g);

     return {
       nodes: g.nodes().map(id => {
         const node = g.node(id);
         return {
           id,
           position: { x: node.x - node.width / 2, y: node.y - node.height / 2 },
           data: node.data,
           type: 'workflowStep'
         };
       }),
       edges: g.edges().map(e => ({
         id: `${e.v}-${e.w}`,
         source: e.v,
         target: e.w,
         markerEnd: { type: MarkerType.ArrowClosed }
       }))
     };
   }
   ```

3. **Custom Node Component**
   ```typescript
   // eui-dashboard/src/components/WorkflowStepNode.tsx
   const statusColors = {
     pending: '#gray',
     running: '#blue',
     completed: '#green',
     failed: '#red',
     skipped: '#yellow'
   };

   export function WorkflowStepNode({ data }: { data: StepNodeData }) {
     return (
       <div style={{
         padding: 10,
         borderRadius: 5,
         border: `2px solid ${statusColors[data.status]}`,
         background: 'white'
       }}>
         <div style={{ fontWeight: 'bold' }}>{data.step.id}</div>
         <div style={{ fontSize: 12, color: '#666' }}>
           {data.step.master} / {data.step.action}
         </div>
         {data.status === 'running' && <Spinner size="s" />}
       </div>
     );
   }
   ```

4. **Workflow Browser Page**
   ```typescript
   // eui-dashboard/src/pages/WorkflowsPage.tsx
   export function WorkflowsPage() {
     const [workflows] = useWorkflows();
     const [selected, setSelected] = useState<string | null>(null);
     const [execution] = useWorkflowExecution(selected);

     return (
       <EuiPage>
         <EuiPageSidebar>
           <WorkflowList
             workflows={workflows}
             onSelect={setSelected}
           />
         </EuiPageSidebar>
         <EuiPageBody>
           {selected && (
             <WorkflowDAG
               workflow={workflows.find(w => w.name === selected)!}
               execution={execution}
             />
           )}
         </EuiPageBody>
       </EuiPage>
     );
   }
   ```

5. **API Endpoint for Workflow Data**
   ```javascript
   // api-server/routes/workflows.js
   router.get('/', async (req, res) => {
     const workflowFiles = await glob('coordination/workflows/*.yaml');
     const workflows = await Promise.all(
       workflowFiles.map(async f => yaml.load(await fs.readFile(f)))
     );
     res.json(workflows);
   });

   router.get('/:name/executions/:id', async (req, res) => {
     const execution = await loadExecution(req.params.name, req.params.id);
     res.json(execution);
   });
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `eui-dashboard/src/components/WorkflowDAG.tsx` | Create | DAG renderer |
| `eui-dashboard/src/components/WorkflowStepNode.tsx` | Create | Custom node |
| `eui-dashboard/src/pages/WorkflowsPage.tsx` | Create | Workflow browser |
| `eui-dashboard/src/hooks/useWorkflows.ts` | Create | Data hooks |
| `api-server/routes/workflows.js` | Create | API endpoints |
| `eui-dashboard/package.json` | Modify | Add dependencies |

---

### 4.2 LLM Spend Dashboard

**Goal**: Token usage, cost per master, and spending trends visualization.

**Priority**: High

#### Implementation Steps

1. **Create Cost Metrics API**
   ```javascript
   // api-server/routes/llm-costs.js
   router.get('/summary', async (req, res) => {
     const { start, end } = req.query;
     const costs = await loadCostMetrics(start, end);

     const summary = {
       total_cost: costs.reduce((sum, c) => sum + c.cost_usd, 0),
       total_tokens: {
         input: costs.reduce((sum, c) => sum + c.input_tokens, 0),
         output: costs.reduce((sum, c) => sum + c.output_tokens, 0)
       },
       by_master: groupBy(costs, 'master'),
       by_model: groupBy(costs, 'model'),
       by_day: groupByDay(costs)
     };

     res.json(summary);
   });

   router.get('/trend', async (req, res) => {
     const { days = 30 } = req.query;
     const trend = await getCostTrend(days);
     res.json(trend);
   });
   ```

2. **Create Dashboard Components**
   ```typescript
   // eui-dashboard/src/components/LLMCostDashboard.tsx
   export function LLMCostDashboard() {
     const [summary] = useCostSummary();
     const [trend] = useCostTrend();

     return (
       <EuiFlexGroup>
         <EuiFlexItem>
           <EuiStat
             title={`$${summary.total_cost.toFixed(2)}`}
             description="Total Spend (30d)"
           />
         </EuiFlexItem>

         <EuiFlexItem>
           <EuiStat
             title={formatNumber(summary.total_tokens.input + summary.total_tokens.output)}
             description="Total Tokens"
           />
         </EuiFlexItem>

         <EuiFlexItem grow={false}>
           <CostByMasterChart data={summary.by_master} />
         </EuiFlexItem>

         <EuiFlexItem>
           <CostTrendChart data={trend} />
         </EuiFlexItem>
       </EuiFlexGroup>
     );
   }
   ```

3. **Cost by Master Pie Chart**
   ```typescript
   // eui-dashboard/src/components/CostByMasterChart.tsx
   import { Chart, Partition, PartitionLayout } from '@elastic/charts';

   export function CostByMasterChart({ data }) {
     return (
       <Chart size={{ height: 200 }}>
         <Partition
           data={data}
           layout={PartitionLayout.sunburst}
           valueAccessor={d => d.cost}
           layers={[
             {
               groupByRollup: d => d.master,
               nodeLabel: d => d[0].master,
               fillLabel: { textInvertible: true }
             }
           ]}
         />
       </Chart>
     );
   }
   ```

4. **Cost Trend Line Chart**
   ```typescript
   // eui-dashboard/src/components/CostTrendChart.tsx
   import { Chart, LineSeries, Axis } from '@elastic/charts';

   export function CostTrendChart({ data }) {
     return (
       <Chart size={{ height: 300 }}>
         <Axis id="bottom" position="bottom" />
         <Axis id="left" position="left" title="Cost ($)" />
         <LineSeries
           id="cost"
           data={data}
           xAccessor="date"
           yAccessors={['cost']}
         />
       </Chart>
     );
   }
   ```

5. **Cost Alerts**
   ```typescript
   // Alert when approaching budget
   export function CostAlerts({ summary }) {
     const budgetUsed = summary.total_cost / summary.monthly_budget;

     if (budgetUsed > 0.9) {
       return (
         <EuiCallOut color="danger" title="Budget Alert">
           You've used {(budgetUsed * 100).toFixed(0)}% of your monthly budget.
         </EuiCallOut>
       );
     }

     return null;
   }
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `api-server/routes/llm-costs.js` | Create | Cost API endpoints |
| `eui-dashboard/src/components/LLMCostDashboard.tsx` | Create | Main dashboard |
| `eui-dashboard/src/components/CostByMasterChart.tsx` | Create | Pie chart |
| `eui-dashboard/src/components/CostTrendChart.tsx` | Create | Trend chart |
| `eui-dashboard/src/components/CostAlerts.tsx` | Create | Budget alerts |
| `eui-dashboard/src/hooks/useCostMetrics.ts` | Create | Data hooks |

---

### 4.3 Decision History Browser

**Goal**: View routing decisions and reasoning for auditability.

**Priority**: Medium

#### Implementation Steps

1. **Create Decision API**
   ```javascript
   // api-server/routes/decisions.js
   router.get('/', async (req, res) => {
     const { limit = 100, master, task_type } = req.query;

     const decisions = await loadDecisions({
       limit,
       filters: { master, task_type }
     });

     res.json(decisions);
   });

   router.get('/:id', async (req, res) => {
     const decision = await getDecision(req.params.id);
     res.json(decision);
   });
   ```

2. **Decision Table Component**
   ```typescript
   // eui-dashboard/src/components/DecisionHistory.tsx
   export function DecisionHistory() {
     const [decisions, loading] = useDecisions();

     const columns = [
       { field: 'timestamp', name: 'Time', sortable: true },
       { field: 'task_id', name: 'Task' },
       { field: 'selected_master', name: 'Master' },
       { field: 'confidence', name: 'Confidence', render: renderConfidence },
       { field: 'reasoning', name: 'Reasoning', truncateText: true },
       {
         name: 'Actions',
         render: (decision) => (
           <EuiButtonIcon
             iconType="inspect"
             onClick={() => showDetails(decision)}
           />
         )
       }
     ];

     return (
       <EuiBasicTable
         items={decisions}
         columns={columns}
         loading={loading}
         sorting={{ sort: { field: 'timestamp', direction: 'desc' } }}
       />
     );
   }
   ```

3. **Decision Detail Flyout**
   ```typescript
   // eui-dashboard/src/components/DecisionDetailFlyout.tsx
   export function DecisionDetailFlyout({ decision, onClose }) {
     return (
       <EuiFlyout onClose={onClose}>
         <EuiFlyoutHeader>
           <EuiTitle>
             <h2>Decision: {decision.task_id}</h2>
           </EuiTitle>
         </EuiFlyoutHeader>

         <EuiFlyoutBody>
           <EuiDescriptionList>
             <EuiDescriptionListTitle>Task Description</EuiDescriptionListTitle>
             <EuiDescriptionListDescription>
               {decision.task_description}
             </EuiDescriptionListDescription>

             <EuiDescriptionListTitle>Selected Master</EuiDescriptionListTitle>
             <EuiDescriptionListDescription>
               {decision.selected_master} ({(decision.confidence * 100).toFixed(0)}%)
             </EuiDescriptionListDescription>

             <EuiDescriptionListTitle>Reasoning</EuiDescriptionListTitle>
             <EuiDescriptionListDescription>
               <pre>{decision.reasoning}</pre>
             </EuiDescriptionListDescription>

             <EuiDescriptionListTitle>Alternative Candidates</EuiDescriptionListTitle>
             <EuiDescriptionListDescription>
               {decision.candidates.map(c => (
                 <div key={c.master}>
                   {c.master}: {(c.score * 100).toFixed(0)}%
                 </div>
               ))}
             </EuiDescriptionListDescription>

             <EuiDescriptionListTitle>Keywords Matched</EuiDescriptionListTitle>
             <EuiDescriptionListDescription>
               {decision.matched_keywords.join(', ')}
             </EuiDescriptionListDescription>
           </EuiDescriptionList>
         </EuiFlyoutBody>
       </EuiFlyout>
     );
   }
   ```

#### Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `api-server/routes/decisions.js` | Create | Decision API |
| `eui-dashboard/src/components/DecisionHistory.tsx` | Create | Decision table |
| `eui-dashboard/src/components/DecisionDetailFlyout.tsx` | Create | Detail view |
| `eui-dashboard/src/hooks/useDecisions.ts` | Create | Data hook |

---

### 4.4 Model/Prompt Versioning Dashboard

**Goal**: Track active prompts and their performance.

**Priority**: Medium

#### Implementation Steps

1. **Prompt Registry**
   ```json
   // llm-mesh/prompts/registry.json
   {
     "prompts": [
       {
         "id": "routing-v3",
         "name": "Task Routing Prompt",
         "version": "3.0",
         "file": "routing/analyze-task.md",
         "created_at": "2024-01-10",
         "active": true,
         "metrics": {
           "avg_confidence": 0.89,
           "accuracy": 0.94,
           "uses": 1523
         }
       }
     ]
   }
   ```

2. **API Endpoints**
   ```javascript
   // api-server/routes/prompts.js
   router.get('/', async (req, res) => {
     const registry = await loadPromptRegistry();
     res.json(registry.prompts);
   });

   router.get('/:id/versions', async (req, res) => {
     const versions = await getPromptVersions(req.params.id);
     res.json(versions);
   });

   router.post('/:id/activate', async (req, res) => {
     await activatePromptVersion(req.params.id, req.body.version);
     res.json({ success: true });
   });
   ```

3. **Dashboard Component**
   ```typescript
   // eui-dashboard/src/components/PromptRegistry.tsx
   export function PromptRegistry() {
     const [prompts] = usePrompts();

     return (
       <EuiBasicTable
         items={prompts}
         columns={[
           { field: 'name', name: 'Prompt' },
           { field: 'version', name: 'Version' },
           {
             field: 'active',
             name: 'Status',
             render: active => (
               <EuiBadge color={active ? 'success' : 'default'}>
                 {active ? 'Active' : 'Inactive'}
               </EuiBadge>
             )
           },
           {
             field: 'metrics',
             name: 'Performance',
             render: m => `${(m.accuracy * 100).toFixed(0)}% accuracy`
           },
           { field: 'metrics.uses', name: 'Uses' }
         ]}
       />
     );
   }
   ```

---

## 5. Quick Wins

### 5.1 Token Counting in LLM Calls

**Location**: `llm-mesh/gateway/llm-client.sh`

**Implementation**:

```bash
# Add to llm-client.sh
count_tokens() {
    local text="$1"
    # Approximate: 1 token ≈ 4 characters
    echo $(( ${#text} / 4 ))
}

# Before API call
input_tokens=$(count_tokens "$prompt")

# After API call
output_tokens=$(echo "$response" | jq -r '.usage.output_tokens // 0')

# Log usage
echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"input_tokens\":$input_tokens,\"output_tokens\":$output_tokens}" >> "$METRICS_DIR/token-usage.jsonl"
```

**Effort**: 1 hour

---

### 5.2 Cost Tracking JSONL

**Location**: `coordination/metrics/llm-costs.jsonl`

**Implementation**:

```bash
# Create cost tracking file
cat > coordination/metrics/llm-costs.jsonl << 'EOF'
EOF

# Add to llm-client.sh after each call
log_cost() {
    local model="$1"
    local input_tokens="$2"
    local output_tokens="$3"

    # Pricing per 1M tokens
    declare -A pricing_input=(
        ["claude-3-haiku-20240307"]=0.25
        ["claude-sonnet-4-20250514"]=3.0
    )
    declare -A pricing_output=(
        ["claude-3-haiku-20240307"]=1.25
        ["claude-sonnet-4-20250514"]=15.0
    )

    local cost=$(echo "scale=6; ($input_tokens * ${pricing_input[$model]} + $output_tokens * ${pricing_output[$model]}) / 1000000" | bc)

    echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"model\":\"$model\",\"input_tokens\":$input_tokens,\"output_tokens\":$output_tokens,\"cost_usd\":$cost}" >> coordination/metrics/llm-costs.jsonl
}
```

**Effort**: 2 hours

---

### 5.3 Review Loop Flag in Task Definitions

**Implementation**:

```json
// coordination/tasks/task-example.json
{
  "task_id": "task-001",
  "description": "Implement user authentication",
  "review": {
    "enabled": true,
    "min_cycles": 1,
    "auto_approve_threshold": 0.9
  }
}
```

```bash
# scripts/spawn-worker.sh addition
if [ "$(jq -r '.review.enabled // false' "$TASK_FILE")" = "true" ]; then
    export REVIEW_ENABLED=true
    export REVIEW_CYCLES=$(jq -r '.review.min_cycles // 1' "$TASK_FILE")
fi
```

**Effort**: 1 hour

---

### 5.4 Document Embeddings Interface

**Location**: `lib/rag/embeddings/README.md`

**Content**:

```markdown
# Embeddings Provider Interface

## Overview

This module provides embedding generation for the RAG system.

## Interface

All embedding providers must implement:

```javascript
class EmbeddingProvider {
  // Generate embedding for single text
  async embed(text: string): Promise<number[]>

  // Generate embeddings for batch
  async embedBatch(texts: string[]): Promise<number[][]>

  // Get embedding dimensions
  getDimensions(): number
}
```

## Current Implementation

- `mock-embedder.js`: Hash-based mock for testing (current)

## Planned Providers

- `openai-embedder.js`: OpenAI text-embedding-3-small
- `ollama-embedder.js`: Local Ollama models
- `anthropic-embedder.js`: Anthropic embeddings (when available)

## Usage

```javascript
const embedder = createEmbedder(config);
const embedding = await embedder.embed("search query");
```

## Configuration

```json
{
  "provider": "openai",
  "model": "text-embedding-3-small",
  "dimensions": 1536
}
```
```

**Effort**: 30 minutes

---

## Implementation Priority Matrix

| Improvement | Impact | Effort | Priority |
|-------------|--------|--------|----------|
| LLM Gateway Pattern | High | Medium | **P0** |
| Real Embeddings | High | Low | **P0** |
| Quality Review Loops | High | Medium | **P0** |
| Token/Cost Tracking | High | Low | **P0** |
| Production Vector Store | High | High | **P1** |
| Task-Based Model Selection | High | Medium | **P1** |
| LLM Cost Dashboard | High | Medium | **P1** |
| Declarative Workflows | Medium | High | **P1** |
| Circuit Breaker | Medium | Medium | **P2** |
| Hybrid Search | Medium | Medium | **P2** |
| Repository Connectors | Medium | High | **P2** |
| Workflow Visualization | Medium | Medium | **P2** |
| Decision History Browser | Medium | Low | **P2** |
| Conditional Branching | Medium | Medium | **P3** |
| SLA Management | Medium | Medium | **P3** |
| Prompt Registry Dashboard | Low | Medium | **P3** |
| Document Conversion | Low | Low | **P3** |
| Knowledge Freshness | Low | Low | **P3** |
| Backpressure | Low | Medium | **P3** |

---

## Next Steps

1. **Phase 1** (Week 1-2): Quick Wins + P0 items
   - Implement token counting and cost tracking
   - Build LLM gateway with Anthropic adapter
   - Add real embeddings (OpenAI)
   - Implement basic review loops

2. **Phase 2** (Week 3-4): P1 items
   - Deploy production vector store (Weaviate)
   - Build LLM cost dashboard
   - Add model selection logic
   - Start declarative workflow engine

3. **Phase 3** (Week 5-6): P2 items
   - Complete workflow visualization
   - Add hybrid search
   - Implement circuit breaker
   - Build decision history browser

4. **Phase 4** (Week 7-8): P3 items and polish
   - Remaining features
   - Testing and documentation
   - Performance optimization
