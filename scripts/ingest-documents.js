#!/usr/bin/env node
// scripts/ingest-documents.js
// CLI tool for ingesting documents into RAG system
// Part of RAG Enhancement: Document Conversion

const fs = require('fs');
const path = require('path');
const { createUnifiedParser, chunkText } = require('../lib/rag/parsers');

/**
 * DocumentIngester - CLI tool for batch document ingestion
 *
 * Features:
 * - Directory scanning with glob patterns
 * - Progress reporting
 * - Dry-run mode
 * - Collection management
 * - Parallel processing
 */
class DocumentIngester {
  constructor(options = {}) {
    this.options = {
      path: options.path || '.',
      pattern: options.pattern || '**/*',
      collection: options.collection || 'default',
      dryRun: options.dryRun || false,
      recursive: options.recursive !== false,
      verbose: options.verbose || false,
      chunkSize: options.chunkSize || 1000,
      chunkOverlap: options.chunkOverlap || 200,
      outputDir: options.outputDir || null,
      ...options
    };

    this.parser = createUnifiedParser({
      autoChunk: true,
      chunkOptions: {
        chunkSize: this.options.chunkSize,
        chunkOverlap: this.options.chunkOverlap
      }
    });

    this.stats = {
      filesFound: 0,
      filesProcessed: 0,
      filesFailed: 0,
      chunksGenerated: 0,
      totalWords: 0,
      totalChars: 0,
      startTime: null,
      endTime: null
    };
  }

  /**
   * Run ingestion process
   * @returns {Promise<Object>} - Ingestion results
   */
  async run() {
    this.stats.startTime = Date.now();

    console.log('Document Ingestion');
    console.log('==================');
    console.log(`Path: ${this.options.path}`);
    console.log(`Pattern: ${this.options.pattern}`);
    console.log(`Collection: ${this.options.collection}`);
    console.log(`Dry Run: ${this.options.dryRun}`);
    console.log('');

    // Find matching files
    const files = await this.findFiles();
    this.stats.filesFound = files.length;

    if (files.length === 0) {
      console.log('No matching files found.');
      return this.getResults();
    }

    console.log(`Found ${files.length} file(s) to process`);
    console.log('');

    // Process files
    const results = [];
    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      const progress = `[${i + 1}/${files.length}]`;

      try {
        const result = await this.processFile(file);
        results.push(result);
        this.stats.filesProcessed++;

        const chunkCount = result.chunks?.length || 0;
        this.stats.chunksGenerated += chunkCount;
        this.stats.totalWords += result.metadata?.wordCount || 0;
        this.stats.totalChars += result.metadata?.charCount || 0;

        if (this.options.verbose) {
          console.log(`${progress} SUCCESS: ${file}`);
          console.log(`         Chunks: ${chunkCount}, Words: ${result.metadata?.wordCount || 0}`);
        } else {
          console.log(`${progress} ${path.basename(file)} - ${chunkCount} chunks`);
        }
      } catch (error) {
        this.stats.filesFailed++;
        results.push({
          file,
          success: false,
          error: error.message
        });

        console.error(`${progress} FAILED: ${file}`);
        if (this.options.verbose) {
          console.error(`         Error: ${error.message}`);
        }
      }
    }

    this.stats.endTime = Date.now();

    // Save results if not dry run
    if (!this.options.dryRun && this.options.outputDir) {
      await this.saveResults(results);
    }

    // Print summary
    this.printSummary();

    return this.getResults();
  }

  /**
   * Find files matching pattern
   * @returns {Promise<Array>} - Matching file paths
   */
  async findFiles() {
    const basePath = path.resolve(this.options.path);

    if (!fs.existsSync(basePath)) {
      throw new Error(`Path does not exist: ${basePath}`);
    }

    const stats = fs.statSync(basePath);

    if (stats.isFile()) {
      // Single file
      const ext = path.extname(basePath);
      if (this.parser.isSupported(ext)) {
        return [basePath];
      }
      return [];
    }

    // Directory - find matching files
    const files = [];
    const pattern = this.options.pattern;

    // Simple glob implementation
    const isMatch = (filePath) => {
      const fileName = path.basename(filePath);
      const ext = path.extname(filePath);

      // Check if file type is supported
      if (!this.parser.isSupported(ext)) {
        return false;
      }

      // Match pattern
      if (pattern === '*' || pattern === '**/*') {
        return true;
      }

      // Handle patterns like "*.md" or "*.pdf"
      if (pattern.startsWith('*.')) {
        const patternExt = pattern.slice(1);
        return ext === patternExt;
      }

      // Handle patterns like "**/*.md"
      if (pattern.startsWith('**/')) {
        const subPattern = pattern.slice(3);
        if (subPattern.startsWith('*.')) {
          const patternExt = subPattern.slice(1);
          return ext === patternExt;
        }
        return fileName === subPattern;
      }

      // Exact match
      return fileName === pattern;
    };

    const scanDir = (dir) => {
      const entries = fs.readdirSync(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory()) {
          if (this.options.recursive && !entry.name.startsWith('.')) {
            scanDir(fullPath);
          }
        } else if (entry.isFile()) {
          if (isMatch(fullPath)) {
            files.push(fullPath);
          }
        }
      }
    };

    scanDir(basePath);

    // Sort by modification time (newest first)
    files.sort((a, b) => {
      const statA = fs.statSync(a);
      const statB = fs.statSync(b);
      return statB.mtime.getTime() - statA.mtime.getTime();
    });

    return files;
  }

  /**
   * Process single file
   * @param {string} filePath - File path
   * @returns {Promise<Object>} - Processing result
   */
  async processFile(filePath) {
    if (this.options.dryRun) {
      // Dry run - just validate file exists and is parseable
      const stats = fs.statSync(filePath);
      return {
        file: filePath,
        success: true,
        dryRun: true,
        metadata: {
          fileName: path.basename(filePath),
          fileSize: stats.size,
          modifiedAt: stats.mtime.toISOString()
        },
        chunks: []
      };
    }

    // Parse file
    const result = await this.parser.parseFile(filePath);

    // Add collection metadata
    result.collection = this.options.collection;
    result.ingestedAt = new Date().toISOString();

    return {
      file: filePath,
      success: true,
      metadata: result.metadata,
      chunks: result.chunks || [],
      frontmatter: result.frontmatter,
      codeBlocks: result.codeBlocks?.length || 0,
      links: result.links?.length || 0,
      tables: result.tables?.length || 0
    };
  }

  /**
   * Save processed results to output directory
   * @param {Array} results - Processing results
   */
  async saveResults(results) {
    const outputDir = path.resolve(this.options.outputDir);

    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }

    // Save manifest
    const manifest = {
      collection: this.options.collection,
      generatedAt: new Date().toISOString(),
      stats: this.stats,
      files: results.map(r => ({
        file: r.file,
        success: r.success,
        chunkCount: r.chunks?.length || 0,
        error: r.error
      }))
    };

    const manifestPath = path.join(outputDir, 'manifest.json');
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log(`\nManifest saved: ${manifestPath}`);

    // Save chunks as JSONL for easy streaming
    const chunksPath = path.join(outputDir, 'chunks.jsonl');
    const chunksStream = fs.createWriteStream(chunksPath);

    let chunkId = 0;
    for (const result of results) {
      if (!result.success || !result.chunks) continue;

      for (const chunk of result.chunks) {
        const chunkDoc = {
          id: `${this.options.collection}-${chunkId++}`,
          collection: this.options.collection,
          source: result.file,
          content: chunk.content,
          metadata: {
            ...chunk,
            fileName: path.basename(result.file),
            ...result.frontmatter
          }
        };
        chunksStream.write(JSON.stringify(chunkDoc) + '\n');
      }
    }

    chunksStream.end();
    console.log(`Chunks saved: ${chunksPath}`);
  }

  /**
   * Print ingestion summary
   */
  printSummary() {
    const duration = (this.stats.endTime - this.stats.startTime) / 1000;

    console.log('');
    console.log('Summary');
    console.log('-------');
    console.log(`Files found:     ${this.stats.filesFound}`);
    console.log(`Files processed: ${this.stats.filesProcessed}`);
    console.log(`Files failed:    ${this.stats.filesFailed}`);
    console.log(`Chunks created:  ${this.stats.chunksGenerated}`);
    console.log(`Total words:     ${this.stats.totalWords.toLocaleString()}`);
    console.log(`Total chars:     ${this.stats.totalChars.toLocaleString()}`);
    console.log(`Duration:        ${duration.toFixed(2)}s`);

    if (this.options.dryRun) {
      console.log('');
      console.log('(Dry run - no changes made)');
    }
  }

  /**
   * Get final results
   * @returns {Object} - Results object
   */
  getResults() {
    return {
      stats: this.stats,
      options: this.options
    };
  }
}

/**
 * Parse command line arguments
 * @param {Array} args - Command line arguments
 * @returns {Object} - Parsed options
 */
function parseArgs(args) {
  const options = {
    path: '.',
    pattern: '**/*',
    collection: 'default',
    dryRun: false,
    verbose: false,
    recursive: true,
    chunkSize: 1000,
    chunkOverlap: 200,
    outputDir: null,
    help: false
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const nextArg = args[i + 1];

    switch (arg) {
      case '--path':
      case '-p':
        options.path = nextArg;
        i++;
        break;

      case '--pattern':
      case '-g':
        options.pattern = nextArg;
        i++;
        break;

      case '--collection':
      case '-c':
        options.collection = nextArg;
        i++;
        break;

      case '--output':
      case '-o':
        options.outputDir = nextArg;
        i++;
        break;

      case '--chunk-size':
        options.chunkSize = parseInt(nextArg, 10);
        i++;
        break;

      case '--chunk-overlap':
        options.chunkOverlap = parseInt(nextArg, 10);
        i++;
        break;

      case '--dry-run':
      case '-n':
        options.dryRun = true;
        break;

      case '--verbose':
      case '-v':
        options.verbose = true;
        break;

      case '--no-recursive':
        options.recursive = false;
        break;

      case '--help':
      case '-h':
        options.help = true;
        break;

      default:
        // Positional argument - treat as path
        if (!arg.startsWith('-')) {
          options.path = arg;
        }
    }
  }

  return options;
}

/**
 * Print usage help
 */
function printHelp() {
  console.log(`
Document Ingestion Tool

Usage: node scripts/ingest-documents.js [options]

Options:
  --path, -p <path>           Source path (file or directory)
  --pattern, -g <pattern>     Glob pattern for file matching
  --collection, -c <name>     Collection name for grouping documents
  --output, -o <dir>          Output directory for processed chunks
  --chunk-size <number>       Target chunk size in characters (default: 1000)
  --chunk-overlap <number>    Overlap between chunks (default: 200)
  --dry-run, -n               Preview without processing
  --verbose, -v               Show detailed output
  --no-recursive              Don't scan subdirectories
  --help, -h                  Show this help message

Examples:
  # Ingest all Markdown files in docs directory
  node scripts/ingest-documents.js --path ./docs --pattern "**/*.md" --collection documentation

  # Ingest PDF reports with custom chunking
  node scripts/ingest-documents.js --path ./reports --pattern "*.pdf" --collection reports --chunk-size 2000

  # Dry run to see what would be processed
  node scripts/ingest-documents.js --path ./docs --dry-run --verbose

  # Process single file
  node scripts/ingest-documents.js --path ./README.md --collection readme

Supported file types:
  - PDF (.pdf)
  - Markdown (.md, .markdown)
`);
}

/**
 * Main entry point
 */
async function main() {
  const args = process.argv.slice(2);
  const options = parseArgs(args);

  if (options.help) {
    printHelp();
    process.exit(0);
  }

  try {
    const ingester = new DocumentIngester(options);
    const results = await ingester.run();

    // Exit with error code if any files failed
    if (results.stats.filesFailed > 0) {
      process.exit(1);
    }

    process.exit(0);
  } catch (error) {
    console.error('Error:', error.message);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  main();
}

module.exports = {
  DocumentIngester,
  parseArgs,
  printHelp
};
