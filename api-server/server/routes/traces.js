/**
 * Traces API Routes
 * Part of Phase 2: Dashboard Trace Visualization
 *
 * Provides API endpoints for retrieving and searching distributed traces.
 */

const express = require('express');
const router = express.Router();
const fs = require('fs').promises;
const fsSync = require('fs');
const path = require('path');
const { sanitizeFilename, validateId, validateDateString, isPathWithinDirectory } = require('../lib/path-validator');

// Configuration
const COMMIT_RELAY_HOME = process.env.COMMIT_RELAY_HOME || path.join(__dirname, '../../..');
const TRACES_DIR = path.join(COMMIT_RELAY_HOME, 'coordination/observability/traces');
const TRACES_ACTIVE_DIR = path.join(TRACES_DIR, 'active');
const TRACES_COMPLETED_DIR = path.join(TRACES_DIR, 'completed');
const TRACES_INDEX_DIR = path.join(TRACES_DIR, 'indices');

/**
 * Read JSON file safely
 */
async function readJSON(filePath) {
    try {
        // Validate the file path is within traces directory
        if (!isPathWithinDirectory(filePath, TRACES_DIR)) {
            console.warn(`Attempted path traversal blocked: ${filePath}`);
            return null;
        }

        const content = await fs.readFile(filePath, 'utf-8');
        return JSON.parse(content);
    } catch (error) {
        console.error(`Error reading ${filePath}:`, error.message);
        return null;
    }
}

/**
 * GET /api/traces
 * List recent traces with optional filtering
 *
 * Query params:
 *   - status: Filter by status (active, completed, error)
 *   - limit: Maximum number of traces to return (default: 50)
 *   - offset: Pagination offset (default: 0)
 *   - task_id: Filter by task ID
 *   - day: Filter by day (YYYY-MM-DD)
 */
router.get('/', async (req, res) => {
    try {
        const { status, limit = 50, offset = 0, task_id, day } = req.query;
        const maxLimit = Math.min(parseInt(limit), 100);
        const startOffset = parseInt(offset);

        let traces = [];

        // Collect traces based on filter
        if (task_id) {
            // Filter by task ID - validate task_id
            const sanitizedTaskId = validateId(task_id);
            if (!sanitizedTaskId) {
                return res.status(400).json({ error: 'Invalid task ID format' });
            }

            const indexFile = path.join(TRACES_INDEX_DIR, `by-task-${sanitizedTaskId}.index`);
            if (!isPathWithinDirectory(indexFile, TRACES_INDEX_DIR)) {
                return res.status(400).json({ error: 'Invalid task ID' });
            }

            if (fsSync.existsSync(indexFile)) {
                const traceIds = (await fs.readFile(indexFile, 'utf-8')).trim().split('\n');
                for (const traceId of traceIds) {
                    const trace = await getTraceById(traceId.trim());
                    if (trace) traces.push(trace);
                }
            }
        } else if (day) {
            // Filter by day - validate date format
            const sanitizedDay = validateDateString(day);
            if (!sanitizedDay) {
                return res.status(400).json({ error: 'Invalid date format. Use YYYY-MM-DD' });
            }

            const indexFile = path.join(TRACES_INDEX_DIR, `by-day-${sanitizedDay}.index`);
            if (!isPathWithinDirectory(indexFile, TRACES_INDEX_DIR)) {
                return res.status(400).json({ error: 'Invalid date' });
            }

            if (fsSync.existsSync(indexFile)) {
                const traceIds = (await fs.readFile(indexFile, 'utf-8')).trim().split('\n');
                for (const traceId of traceIds) {
                    const trace = await getTraceById(traceId.trim());
                    if (trace) traces.push(trace);
                }
            }
        } else {
            // Get all traces from both active and completed directories
            const activeTraces = await getTracesFromDir(TRACES_ACTIVE_DIR);
            const completedTraces = await getTracesFromDir(TRACES_COMPLETED_DIR);
            traces = [...activeTraces, ...completedTraces];
        }

        // Filter by status if specified
        if (status) {
            traces = traces.filter(t => t.status === status);
        }

        // Sort by start_time descending (most recent first)
        traces.sort((a, b) => (b.start_time || 0) - (a.start_time || 0));

        // Pagination
        const total = traces.length;
        const paginatedTraces = traces.slice(startOffset, startOffset + maxLimit);

        // Return summary info for list view
        const traceSummaries = paginatedTraces.map(t => ({
            trace_id: t.trace_id,
            status: t.status,
            start_time: t.start_time,
            end_time: t.end_time,
            duration_ms: t.duration_ms,
            span_count: t.span_count || (t.spans ? t.spans.length : 0),
            error_count: t.error_count || 0,
            root_operation: t.spans && t.spans.length > 0 ? t.spans[0].name : 'unknown',
            attributes: t.attributes || {}
        }));

        res.json({
            traces: traceSummaries,
            pagination: {
                total,
                limit: maxLimit,
                offset: startOffset,
                has_more: (startOffset + maxLimit) < total
            }
        });
    } catch (error) {
        console.error('Error listing traces:', error);
        res.status(500).json({ error: 'Failed to list traces' });
    }
});

/**
 * GET /api/traces/:traceId
 * Get a specific trace by ID with all spans
 */
router.get('/:traceId', async (req, res) => {
    try {
        const { traceId } = req.params;

        if (!traceId || traceId.length < 10) {
            return res.status(400).json({ error: 'Invalid trace ID' });
        }

        const trace = await getTraceById(traceId);

        if (!trace) {
            return res.status(404).json({ error: 'Trace not found' });
        }

        res.json(trace);
    } catch (error) {
        console.error('Error getting trace:', error);
        res.status(500).json({ error: 'Failed to get trace' });
    }
});

/**
 * GET /api/traces/:traceId/spans
 * Get spans for a specific trace
 */
router.get('/:traceId/spans', async (req, res) => {
    try {
        const { traceId } = req.params;

        const trace = await getTraceById(traceId);

        if (!trace) {
            return res.status(404).json({ error: 'Trace not found' });
        }

        res.json({
            trace_id: traceId,
            spans: trace.spans || []
        });
    } catch (error) {
        console.error('Error getting spans:', error);
        res.status(500).json({ error: 'Failed to get spans' });
    }
});

/**
 * GET /api/traces/stats/summary
 * Get trace statistics summary
 *
 * Query params:
 *   - timeframe: Statistics timeframe (today, yesterday, last_7d)
 */
router.get('/stats/summary', async (req, res) => {
    try {
        const { timeframe = 'today' } = req.query;

        let day = '';
        const now = new Date();

        switch (timeframe) {
            case 'today':
                day = now.toISOString().split('T')[0];
                break;
            case 'yesterday':
                const yesterday = new Date(now);
                yesterday.setDate(yesterday.getDate() - 1);
                day = yesterday.toISOString().split('T')[0];
                break;
            case 'last_7d':
                // Aggregate over last 7 days
                const stats = await get7DayStats();
                return res.json(stats);
            default:
                day = timeframe;
        }

        // Get stats for specific day
        const indexFile = path.join(TRACES_INDEX_DIR, `by-day-${day}.index`);

        if (!fsSync.existsSync(indexFile)) {
            return res.json({
                day,
                trace_count: 0,
                error_count: 0,
                success_rate: 0,
                avg_duration_ms: 0
            });
        }

        const traceIds = (await fs.readFile(indexFile, 'utf-8')).trim().split('\n').filter(id => id);
        let totalDuration = 0;
        let errorCount = 0;
        let traceCount = traceIds.length;

        for (const traceId of traceIds) {
            const trace = await getTraceById(traceId);
            if (trace) {
                if (trace.status === 'error') errorCount++;
                totalDuration += trace.duration_ms || 0;
            }
        }

        const avgDuration = traceCount > 0 ? Math.round(totalDuration / traceCount) : 0;
        const successRate = traceCount > 0 ? ((traceCount - errorCount) / traceCount * 100).toFixed(2) : 0;

        res.json({
            day,
            trace_count: traceCount,
            error_count: errorCount,
            success_rate: parseFloat(successRate),
            avg_duration_ms: avgDuration
        });
    } catch (error) {
        console.error('Error getting trace stats:', error);
        res.status(500).json({ error: 'Failed to get trace statistics' });
    }
});

/**
 * GET /api/traces/search
 * Search traces by various criteria
 *
 * Query params:
 *   - query: Search in trace/span names and attributes
 *   - min_duration: Minimum duration in ms
 *   - max_duration: Maximum duration in ms
 *   - has_errors: Filter for traces with errors (true/false)
 *   - limit: Maximum results (default: 50)
 */
router.get('/search', async (req, res) => {
    try {
        const { query, min_duration, max_duration, has_errors, limit = 50 } = req.query;
        const maxLimit = Math.min(parseInt(limit), 100);

        // Get all completed traces
        const traces = await getTracesFromDir(TRACES_COMPLETED_DIR);

        let filteredTraces = traces;

        // Apply filters
        if (min_duration) {
            const minMs = parseInt(min_duration);
            filteredTraces = filteredTraces.filter(t => (t.duration_ms || 0) >= minMs);
        }

        if (max_duration) {
            const maxMs = parseInt(max_duration);
            filteredTraces = filteredTraces.filter(t => (t.duration_ms || 0) <= maxMs);
        }

        if (has_errors === 'true') {
            filteredTraces = filteredTraces.filter(t => (t.error_count || 0) > 0);
        } else if (has_errors === 'false') {
            filteredTraces = filteredTraces.filter(t => (t.error_count || 0) === 0);
        }

        if (query) {
            const searchLower = query.toLowerCase();
            filteredTraces = filteredTraces.filter(t => {
                // Search in trace attributes
                const attrMatch = JSON.stringify(t.attributes || {}).toLowerCase().includes(searchLower);

                // Search in span names
                const spanMatch = (t.spans || []).some(s =>
                    s.name.toLowerCase().includes(searchLower) ||
                    JSON.stringify(s.attributes || {}).toLowerCase().includes(searchLower)
                );

                return attrMatch || spanMatch;
            });
        }

        // Sort by start time descending
        filteredTraces.sort((a, b) => (b.start_time || 0) - (a.start_time || 0));

        // Limit results
        const results = filteredTraces.slice(0, maxLimit);

        res.json({
            traces: results.map(t => ({
                trace_id: t.trace_id,
                status: t.status,
                start_time: t.start_time,
                duration_ms: t.duration_ms,
                span_count: t.spans ? t.spans.length : 0,
                error_count: t.error_count || 0
            })),
            total: filteredTraces.length,
            limit: maxLimit
        });
    } catch (error) {
        console.error('Error searching traces:', error);
        res.status(500).json({ error: 'Failed to search traces' });
    }
});

/**
 * Helper: Get trace by ID from active or completed directory
 */
async function getTraceById(traceId) {
    // Check active first
    const activePath = path.join(TRACES_ACTIVE_DIR, `${traceId}.json`);
    if (fsSync.existsSync(activePath)) {
        return await readJSON(activePath);
    }

    // Check completed
    const completedPath = path.join(TRACES_COMPLETED_DIR, `${traceId}.json`);
    if (fsSync.existsSync(completedPath)) {
        return await readJSON(completedPath);
    }

    return null;
}

/**
 * Helper: Get all traces from a directory
 */
async function getTracesFromDir(dir) {
    const traces = [];

    if (!fsSync.existsSync(dir)) {
        return traces;
    }

    try {
        const files = await fs.readdir(dir);

        for (const file of files) {
            if (file.endsWith('.json') && !file.includes('.span')) {
                const trace = await readJSON(path.join(dir, file));
                if (trace && trace.trace_id) {
                    traces.push(trace);
                }
            }
        }
    } catch (error) {
        console.error(`Error reading traces from ${dir}:`, error);
    }

    return traces;
}

/**
 * Helper: Get aggregated stats for last 7 days
 */
async function get7DayStats() {
    const now = new Date();
    const days = [];
    let totalTraces = 0;
    let totalErrors = 0;
    let totalDuration = 0;

    for (let i = 0; i < 7; i++) {
        const date = new Date(now);
        date.setDate(date.getDate() - i);
        const day = date.toISOString().split('T')[0];

        const indexFile = path.join(TRACES_INDEX_DIR, `by-day-${day}.index`);

        let dayStats = {
            day,
            trace_count: 0,
            error_count: 0,
            avg_duration_ms: 0
        };

        if (fsSync.existsSync(indexFile)) {
            const traceIds = (await fs.readFile(indexFile, 'utf-8')).trim().split('\n').filter(id => id);
            let dayDuration = 0;

            for (const traceId of traceIds) {
                const trace = await getTraceById(traceId);
                if (trace) {
                    dayStats.trace_count++;
                    if (trace.status === 'error') dayStats.error_count++;
                    dayDuration += trace.duration_ms || 0;
                }
            }

            dayStats.avg_duration_ms = dayStats.trace_count > 0
                ? Math.round(dayDuration / dayStats.trace_count)
                : 0;

            totalTraces += dayStats.trace_count;
            totalErrors += dayStats.error_count;
            totalDuration += dayDuration;
        }

        days.push(dayStats);
    }

    return {
        timeframe: 'last_7d',
        total_traces: totalTraces,
        total_errors: totalErrors,
        success_rate: totalTraces > 0 ? ((totalTraces - totalErrors) / totalTraces * 100).toFixed(2) : 0,
        avg_duration_ms: totalTraces > 0 ? Math.round(totalDuration / totalTraces) : 0,
        daily_breakdown: days
    };
}

module.exports = router;
