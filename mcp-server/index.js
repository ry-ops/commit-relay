#!/usr/bin/env node
/**
 * Commit-Relay MCP Server
 *
 * Model Context Protocol server that exposes commit-relay capabilities
 * as standardized Tools and Resources for AI agents.
 *
 * Protocol: JSON-RPC 2.0 over stdio
 * Spec: https://modelcontextprotocol.io
 */

const readline = require('readline');
const fs = require('fs').promises;
const path = require('path');
const { spawn } = require('child_process');

// Server configuration
const SERVER_NAME = 'commit-relay-mcp';
const SERVER_VERSION = '1.0.0';
const COMMIT_RELAY_HOME = process.env.COMMIT_RELAY_HOME || path.resolve(__dirname, '..');

// Tool definitions
const tools = require('./tools');
const resources = require('./resources');

class MCPServer {
  constructor() {
    this.rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
      terminal: false
    });

    this.initialized = false;
  }

  async start() {
    this.rl.on('line', async (line) => {
      try {
        const request = JSON.parse(line);
        const response = await this.handleRequest(request);
        if (response) {
          this.send(response);
        }
      } catch (error) {
        this.sendError(null, -32700, 'Parse error', error.message);
      }
    });

    this.rl.on('close', () => {
      process.exit(0);
    });
  }

  send(message) {
    console.log(JSON.stringify(message));
  }

  sendError(id, code, message, data = null) {
    const error = { code, message };
    if (data) error.data = data;
    this.send({
      jsonrpc: '2.0',
      id,
      error
    });
  }

  sendResult(id, result) {
    this.send({
      jsonrpc: '2.0',
      id,
      result
    });
  }

  async handleRequest(request) {
    const { id, method, params } = request;

    // Handle notifications (no id)
    if (id === undefined) {
      await this.handleNotification(method, params);
      return null;
    }

    try {
      let result;

      switch (method) {
        case 'initialize':
          result = await this.handleInitialize(params);
          break;
        case 'tools/list':
          result = await this.handleToolsList();
          break;
        case 'tools/call':
          result = await this.handleToolCall(params);
          break;
        case 'resources/list':
          result = await this.handleResourcesList();
          break;
        case 'resources/read':
          result = await this.handleResourceRead(params);
          break;
        case 'prompts/list':
          result = await this.handlePromptsList();
          break;
        default:
          this.sendError(id, -32601, 'Method not found', `Unknown method: ${method}`);
          return null;
      }

      this.sendResult(id, result);
    } catch (error) {
      this.sendError(id, -32603, 'Internal error', error.message);
    }

    return null;
  }

  async handleNotification(method, params) {
    switch (method) {
      case 'notifications/initialized':
        this.initialized = true;
        break;
      case 'notifications/cancelled':
        // Handle cancellation if needed
        break;
    }
  }

  async handleInitialize(params) {
    return {
      protocolVersion: '2024-11-05',
      capabilities: {
        tools: {},
        resources: {},
        prompts: {}
      },
      serverInfo: {
        name: SERVER_NAME,
        version: SERVER_VERSION
      }
    };
  }

  async handleToolsList() {
    return {
      tools: tools.getToolDefinitions()
    };
  }

  async handleToolCall(params) {
    const { name, arguments: args } = params;

    const tool = tools.getTool(name);
    if (!tool) {
      throw new Error(`Unknown tool: ${name}`);
    }

    const result = await tool.execute(args, COMMIT_RELAY_HOME);

    return {
      content: [
        {
          type: 'text',
          text: typeof result === 'string' ? result : JSON.stringify(result, null, 2)
        }
      ]
    };
  }

  async handleResourcesList() {
    return {
      resources: resources.getResourceDefinitions(COMMIT_RELAY_HOME)
    };
  }

  async handleResourceRead(params) {
    const { uri } = params;

    const content = await resources.readResource(uri, COMMIT_RELAY_HOME);

    return {
      contents: [
        {
          uri,
          mimeType: 'application/json',
          text: typeof content === 'string' ? content : JSON.stringify(content, null, 2)
        }
      ]
    };
  }

  async handlePromptsList() {
    return {
      prompts: []
    };
  }
}

// Start server
const server = new MCPServer();
server.start();
