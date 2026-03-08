#!/usr/bin/env node
// lib/rag/search/fusion.js
// Result Fusion Algorithms for Hybrid Search
// Part of Hybrid Search Implementation for commit-relay RAG

/**
 * Reciprocal Rank Fusion (RRF) Algorithm
 * Combines multiple ranked result sets into a single ranking
 *
 * RRF Score = sum(1 / (k + rank_i)) for all result sets
 *
 * @param {Array<Array>} resultSets - Array of result arrays, each sorted by relevance
 * @param {number} k - Ranking constant (default: 60, higher = more weight to lower-ranked items)
 * @returns {Array} - Fused results sorted by combined RRF score
 */
function reciprocalRankFusion(resultSets, k = 60) {
  // Map to accumulate RRF scores by document ID
  const fusedScores = new Map();
  // Map to store document data by ID
  const documents = new Map();

  // Process each result set
  for (let setIndex = 0; setIndex < resultSets.length; setIndex++) {
    const results = resultSets[setIndex];

    for (let rank = 0; rank < results.length; rank++) {
      const doc = results[rank];
      const docId = doc.id;

      // Calculate RRF score contribution from this result set
      // rank + 1 because ranks start at 0 but RRF uses 1-based ranking
      const rrfScore = 1 / (k + rank + 1);

      // Accumulate score
      const currentScore = fusedScores.get(docId) || 0;
      fusedScores.set(docId, currentScore + rrfScore);

      // Store document data (use first occurrence)
      if (!documents.has(docId)) {
        documents.set(docId, {
          ...doc,
          rankContributions: []
        });
      }

      // Track rank contributions for debugging
      const docData = documents.get(docId);
      docData.rankContributions.push({
        setIndex,
        rank: rank + 1,
        contribution: rrfScore
      });
    }
  }

  // Build final results array
  const fusedResults = [];
  for (const [docId, score] of fusedScores) {
    const docData = documents.get(docId);
    fusedResults.push({
      ...docData,
      id: docId,
      fusedScore: score,
      // Normalize to 0-1 range based on max possible score
      normalizedScore: score / (resultSets.length / (k + 1))
    });
  }

  // Sort by fused score (descending)
  fusedResults.sort((a, b) => b.fusedScore - a.fusedScore);

  return fusedResults;
}

/**
 * Weighted Score Fusion
 * Combines results using weighted average of scores
 *
 * @param {Array<Array>} resultSets - Array of result arrays with scores
 * @param {Array<number>} weights - Weights for each result set (should sum to 1)
 * @returns {Array} - Fused results sorted by weighted score
 */
function weightedScoreFusion(resultSets, weights = null) {
  // Default to equal weights
  if (!weights) {
    weights = resultSets.map(() => 1 / resultSets.length);
  }

  // Normalize weights if they don't sum to 1
  const weightSum = weights.reduce((sum, w) => sum + w, 0);
  const normalizedWeights = weights.map(w => w / weightSum);

  // Map to accumulate weighted scores by document ID
  const fusedScores = new Map();
  // Map to store document data by ID
  const documents = new Map();

  // Process each result set
  for (let setIndex = 0; setIndex < resultSets.length; setIndex++) {
    const results = resultSets[setIndex];
    const weight = normalizedWeights[setIndex];

    for (const doc of results) {
      const docId = doc.id;
      const score = doc.score || doc.similarity || 0;

      // Calculate weighted score contribution
      const weightedScore = score * weight;

      // Accumulate score
      const currentScore = fusedScores.get(docId) || 0;
      fusedScores.set(docId, currentScore + weightedScore);

      // Store document data (use first occurrence or merge)
      if (!documents.has(docId)) {
        documents.set(docId, {
          ...doc,
          scoreContributions: []
        });
      }

      // Track contributions for debugging
      const docData = documents.get(docId);
      docData.scoreContributions.push({
        setIndex,
        originalScore: score,
        weight,
        contribution: weightedScore
      });
    }
  }

  // Build final results array
  const fusedResults = [];
  for (const [docId, score] of fusedScores) {
    const docData = documents.get(docId);
    fusedResults.push({
      ...docData,
      id: docId,
      fusedScore: score
    });
  }

  // Sort by fused score (descending)
  fusedResults.sort((a, b) => b.fusedScore - a.fusedScore);

  return fusedResults;
}

/**
 * Convex Combination Fusion
 * Combines keyword and semantic scores using alpha parameter
 *
 * Combined Score = alpha * semantic_score + (1 - alpha) * keyword_score
 *
 * @param {Array} semanticResults - Semantic search results with similarity scores
 * @param {Array} keywordResults - Keyword search results with scores
 * @param {number} alpha - Weight for semantic scores (0 = keyword only, 1 = semantic only)
 * @returns {Array} - Fused results sorted by combined score
 */
function convexCombinationFusion(semanticResults, keywordResults, alpha = 0.7) {
  // Map to store combined scores by document ID
  const combinedScores = new Map();
  // Map to store document data
  const documents = new Map();

  // Process semantic results
  for (const doc of semanticResults) {
    const docId = doc.id;
    const semanticScore = doc.similarity || doc.score || 0;

    documents.set(docId, {
      ...doc,
      semanticScore
    });

    combinedScores.set(docId, {
      semantic: semanticScore,
      keyword: 0
    });
  }

  // Process keyword results
  for (const doc of keywordResults) {
    const docId = doc.id;
    const keywordScore = doc.score || 0;

    if (!documents.has(docId)) {
      documents.set(docId, {
        ...doc,
        keywordScore
      });
      combinedScores.set(docId, {
        semantic: 0,
        keyword: keywordScore
      });
    } else {
      const existing = combinedScores.get(docId);
      existing.keyword = keywordScore;
      documents.get(docId).keywordScore = keywordScore;
    }
  }

  // Calculate combined scores
  const fusedResults = [];
  for (const [docId, scores] of combinedScores) {
    const docData = documents.get(docId);
    const combinedScore = alpha * scores.semantic + (1 - alpha) * scores.keyword;

    fusedResults.push({
      ...docData,
      id: docId,
      fusedScore: combinedScore,
      semanticScore: scores.semantic,
      keywordScore: scores.keyword,
      alpha
    });
  }

  // Sort by combined score (descending)
  fusedResults.sort((a, b) => b.fusedScore - a.fusedScore);

  return fusedResults;
}

/**
 * CombMNZ Fusion
 * Combines results using CombMNZ algorithm
 * Final score = sum of normalized scores * number of sets containing the document
 *
 * @param {Array<Array>} resultSets - Array of result arrays with scores
 * @returns {Array} - Fused results sorted by CombMNZ score
 */
function combMNZ(resultSets) {
  // Map to accumulate scores by document ID
  const scoreAccumulator = new Map();
  // Map to count appearances
  const appearanceCount = new Map();
  // Map to store document data
  const documents = new Map();

  // Process each result set
  for (const results of resultSets) {
    // Find max score for normalization
    const maxScore = results.length > 0
      ? Math.max(...results.map(r => r.score || r.similarity || 0))
      : 1;

    for (const doc of results) {
      const docId = doc.id;
      const normalizedScore = (doc.score || doc.similarity || 0) / maxScore;

      // Accumulate normalized score
      const currentScore = scoreAccumulator.get(docId) || 0;
      scoreAccumulator.set(docId, currentScore + normalizedScore);

      // Increment appearance count
      const count = appearanceCount.get(docId) || 0;
      appearanceCount.set(docId, count + 1);

      // Store document data
      if (!documents.has(docId)) {
        documents.set(docId, doc);
      }
    }
  }

  // Calculate CombMNZ scores
  const fusedResults = [];
  for (const [docId, scoreSum] of scoreAccumulator) {
    const count = appearanceCount.get(docId);
    const docData = documents.get(docId);

    fusedResults.push({
      ...docData,
      id: docId,
      fusedScore: scoreSum * count,
      appearanceCount: count,
      scoreSum
    });
  }

  // Sort by CombMNZ score (descending)
  fusedResults.sort((a, b) => b.fusedScore - a.fusedScore);

  return fusedResults;
}

/**
 * Interleave results from multiple sources
 * Useful for diversity in results
 *
 * @param {Array<Array>} resultSets - Array of result arrays
 * @param {number} limit - Maximum results to return
 * @returns {Array} - Interleaved results
 */
function interleave(resultSets, limit = 10) {
  const interleaved = [];
  const seen = new Set();
  let i = 0;

  while (interleaved.length < limit) {
    let added = false;

    for (const results of resultSets) {
      if (i < results.length) {
        const doc = results[i];
        if (!seen.has(doc.id)) {
          interleaved.push(doc);
          seen.add(doc.id);
          added = true;

          if (interleaved.length >= limit) break;
        }
      }
    }

    if (!added) break;
    i++;
  }

  return interleaved;
}

module.exports = {
  reciprocalRankFusion,
  weightedScoreFusion,
  convexCombinationFusion,
  combMNZ,
  interleave
};
