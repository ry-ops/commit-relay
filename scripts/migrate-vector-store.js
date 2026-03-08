#!/usr/bin/env node
// scripts/migrate-vector-store.js
// Vector Store Migration Script
// Migrate data between different vector store providers

const fs = require('fs').promises;
const path = require('path');

// Import store factory
const {
  createStore,
  createStoreFromConfig,
  getAvailableProviders
} = require('../lib/rag/stores');

/**
 * Migrate data from source store to target store
 */
async function migrateStore(sourceConfig, targetConfig, options = {}) {
  const batchSize = options.batchSize || 100;
  const dryRun = options.dryRun || false;
  const preserveIds = options.preserveIds !== false;

  console.log('=== Vector Store Migration ===\n');

  // Create source and target stores
  console.log('Connecting to source store...');
  const sourceStore = createStore(sourceConfig);
  await sourceStore.connect();
  console.log(`Source: ${sourceStore.getName()}`);

  console.log('Connecting to target store...');
  const targetStore = createStore(targetConfig);
  await targetStore.connect();
  console.log(`Target: ${targetStore.getName()}\n`);

  // Get source collections
  const collections = await sourceStore.listCollections();
  console.log(`Found ${collections.length} collections to migrate\n`);

  const results = {
    collections: {},
    totalMigrated: 0,
    totalFailed: 0,
    startTime: new Date(),
    endTime: null
  };

  // Migrate each collection
  for (const collectionName of collections) {
    console.log(`\nMigrating collection: ${collectionName}`);

    try {
      // Get collection info from source
      const collInfo = await sourceStore.getCollectionInfo(collectionName);
      console.log(`  Documents: ${collInfo.count || collInfo.pointsCount || 'unknown'}`);

      // Create collection in target
      if (!dryRun) {
        const exists = await targetStore.collectionExists(collectionName);
        if (!exists) {
          await targetStore.createCollection(collectionName, {
            dimension: collInfo.dimension || collInfo.config?.params?.vectors?.size || 1536,
            distance: collInfo.distance || 'cosine',
            description: collInfo.description || ''
          });
          console.log(`  Created collection in target`);
        } else {
          console.log(`  Collection exists in target`);
        }
      }

      // Migrate documents in batches
      let offset = 0;
      let migrated = 0;
      let failed = 0;

      while (true) {
        // Get batch from source
        const documents = await sourceStore.getAll(collectionName, {
          limit: batchSize,
          offset: offset,
          includeVectors: true
        });

        if (documents.length === 0) {
          break;
        }

        // Transform documents for insertion
        const docsToInsert = documents.map(doc => ({
          id: preserveIds ? doc.id : undefined,
          vector: doc.vector,
          content: doc.content,
          metadata: doc.metadata
        }));

        // Insert into target
        if (!dryRun) {
          try {
            await targetStore.insert(collectionName, docsToInsert);
            migrated += documents.length;
          } catch (error) {
            console.error(`  Error inserting batch: ${error.message}`);
            failed += documents.length;
          }
        } else {
          migrated += documents.length;
        }

        offset += documents.length;
        process.stdout.write(`  Progress: ${offset} documents processed\r`);
      }

      console.log(`  Completed: ${migrated} migrated, ${failed} failed`);

      results.collections[collectionName] = {
        migrated,
        failed,
        total: migrated + failed
      };
      results.totalMigrated += migrated;
      results.totalFailed += failed;

    } catch (error) {
      console.error(`  Failed to migrate collection: ${error.message}`);
      results.collections[collectionName] = {
        error: error.message,
        migrated: 0,
        failed: 0
      };
    }
  }

  // Cleanup
  await sourceStore.disconnect();
  await targetStore.disconnect();

  results.endTime = new Date();
  results.durationMs = results.endTime - results.startTime;

  console.log('\n=== Migration Complete ===');
  console.log(`Total migrated: ${results.totalMigrated}`);
  console.log(`Total failed: ${results.totalFailed}`);
  console.log(`Duration: ${results.durationMs}ms`);

  if (dryRun) {
    console.log('\n(Dry run - no data was actually migrated)');
  }

  return results;
}

/**
 * Backup store to file
 */
async function backupStore(storeConfig, backupPath, options = {}) {
  console.log('=== Vector Store Backup ===\n');

  const store = createStore(storeConfig);
  await store.connect();
  console.log(`Backing up from: ${store.getName()}`);

  const backup = {
    version: '1.0.0',
    provider: store.getName(),
    created_at: new Date().toISOString(),
    collections: {}
  };

  const collections = await store.listCollections();
  console.log(`Collections: ${collections.length}\n`);

  for (const collectionName of collections) {
    console.log(`Backing up: ${collectionName}`);

    const info = await store.getCollectionInfo(collectionName);
    const documents = await store.getAll(collectionName, {
      limit: 10000,
      includeVectors: true
    });

    backup.collections[collectionName] = {
      info,
      documents
    };

    console.log(`  Documents: ${documents.length}`);
  }

  await store.disconnect();

  // Save backup
  const actualPath = backupPath || `vector-store-backup-${Date.now()}.json`;
  await fs.writeFile(actualPath, JSON.stringify(backup, null, 2));
  console.log(`\nBackup saved to: ${actualPath}`);

  return actualPath;
}

/**
 * Restore store from backup
 */
async function restoreStore(storeConfig, backupPath, options = {}) {
  console.log('=== Vector Store Restore ===\n');

  // Load backup
  const backupContent = await fs.readFile(backupPath, 'utf8');
  const backup = JSON.parse(backupContent);
  console.log(`Backup version: ${backup.version}`);
  console.log(`Created: ${backup.created_at}`);
  console.log(`Collections: ${Object.keys(backup.collections).length}\n`);

  const store = createStore(storeConfig);
  await store.connect();
  console.log(`Restoring to: ${store.getName()}\n`);

  let totalRestored = 0;

  for (const [collectionName, collData] of Object.entries(backup.collections)) {
    console.log(`Restoring: ${collectionName}`);

    // Create collection
    const exists = await store.collectionExists(collectionName);
    if (!exists) {
      await store.createCollection(collectionName, {
        dimension: collData.info.dimension || 1536,
        distance: collData.info.distance || 'cosine',
        description: collData.info.description || ''
      });
    } else if (options.clearExisting) {
      await store.clear(collectionName);
    }

    // Insert documents
    const docsToInsert = collData.documents.map(doc => ({
      id: doc.id,
      vector: doc.vector,
      content: doc.content,
      metadata: doc.metadata
    }));

    await store.insert(collectionName, docsToInsert);
    totalRestored += docsToInsert.length;
    console.log(`  Restored: ${docsToInsert.length} documents`);
  }

  await store.disconnect();

  console.log(`\nTotal restored: ${totalRestored} documents`);
  return totalRestored;
}

/**
 * Verify migration between two stores
 */
async function verifyMigration(sourceConfig, targetConfig) {
  console.log('=== Migration Verification ===\n');

  const sourceStore = createStore(sourceConfig);
  await sourceStore.connect();

  const targetStore = createStore(targetConfig);
  await targetStore.connect();

  const sourceCollections = await sourceStore.listCollections();
  const targetCollections = await targetStore.listCollections();

  let allMatch = true;

  for (const coll of sourceCollections) {
    const sourceCount = await sourceStore.count(coll);
    const targetCount = await targetStore.count(coll);

    const match = sourceCount === targetCount;
    const status = match ? '[OK]' : '[MISMATCH]';

    console.log(`${status} ${coll}: source=${sourceCount}, target=${targetCount}`);

    if (!match) allMatch = false;
  }

  // Check for extra collections in target
  for (const coll of targetCollections) {
    if (!sourceCollections.includes(coll)) {
      console.log(`[EXTRA] ${coll}: only in target`);
      allMatch = false;
    }
  }

  await sourceStore.disconnect();
  await targetStore.disconnect();

  console.log(`\nVerification: ${allMatch ? 'PASSED' : 'FAILED'}`);
  return allMatch;
}

// CLI interface
if (require.main === module) {
  const args = process.argv.slice(2);
  const action = args[0];

  (async () => {
    try {
      switch (action) {
        case 'migrate': {
          const source = args[1];
          const target = args[2];

          if (!source || !target) {
            console.error('Usage: migrate <source-provider> <target-provider> [--dry-run]');
            console.error('Example: migrate file qdrant');
            process.exit(1);
          }

          const dryRun = args.includes('--dry-run');

          await migrateStore(
            { provider: source },
            { provider: target },
            { dryRun, batchSize: 100 }
          );
          break;
        }

        case 'backup': {
          const provider = args[1] || 'file';
          const outputPath = args[2];

          await backupStore({ provider }, outputPath);
          break;
        }

        case 'restore': {
          const backupPath = args[1];
          const provider = args[2] || 'file';

          if (!backupPath) {
            console.error('Usage: restore <backup-file> [provider]');
            process.exit(1);
          }

          await restoreStore({ provider }, backupPath, { clearExisting: true });
          break;
        }

        case 'verify': {
          const source = args[1];
          const target = args[2];

          if (!source || !target) {
            console.error('Usage: verify <source-provider> <target-provider>');
            process.exit(1);
          }

          const passed = await verifyMigration(
            { provider: source },
            { provider: target }
          );

          process.exit(passed ? 0 : 1);
          break;
        }

        default:
          console.log('Vector Store Migration Tool');
          console.log('');
          console.log('Usage: node migrate-vector-store.js <action> [options]');
          console.log('');
          console.log('Actions:');
          console.log('  migrate <source> <target> [--dry-run]');
          console.log('    Migrate data from source to target provider');
          console.log('    Example: migrate file qdrant');
          console.log('');
          console.log('  backup [provider] [output-file]');
          console.log('    Backup store to JSON file');
          console.log('    Example: backup file my-backup.json');
          console.log('');
          console.log('  restore <backup-file> [provider]');
          console.log('    Restore store from backup');
          console.log('    Example: restore my-backup.json qdrant');
          console.log('');
          console.log('  verify <source> <target>');
          console.log('    Verify migration between stores');
          console.log('    Example: verify file qdrant');
          console.log('');
          console.log('Available providers:', getAvailableProviders().join(', '));
          break;
      }
    } catch (error) {
      console.error('Error:', error.message);
      process.exit(1);
    }
  })();
}

module.exports = {
  migrateStore,
  backupStore,
  restoreStore,
  verifyMigration
};
