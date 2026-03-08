#!/usr/bin/env python3
"""
PDF Analysis Script for Commit-Relay Upgrade Paths
Analyzes PDFs, identifies relevant upgrade paths, and creates implementation prompts.
"""

import os
import re
from pathlib import Path
from pypdf import PdfReader
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch

# Commit-relay capabilities and potential upgrade areas
COMMIT_RELAY_CONTEXT = {
    'current_capabilities': [
        'Multi-agent orchestration with master/worker architecture',
        'MoE (Mixture of Experts) routing and learning',
        'Token budget management',
        'Distributed tracing and observability',
        'Agent registry and lifecycle management',
        'RAG pipeline for document processing',
        'Security scanning and threat detection',
        'CI/CD automation',
        'Dashboard monitoring',
        'Self-healing daemon infrastructure'
    ],
    'upgrade_keywords': {
        'ai_agents': ['agent', 'agentic', 'autonomous', 'orchestration', 'multi-agent', 'llm', 'reasoning'],
        'observability': ['observability', 'monitoring', 'tracing', 'metrics', 'logging', 'telemetry', 'dashboards'],
        'security': ['security', 'threat', 'vulnerability', 'ransomware', 'incident', 'compliance', 'nist', 'risk'],
        'data_management': ['data warehouse', 'analytics', 'data governance', 'data management', 'etl', 'pipeline'],
        'api_management': ['api', 'lifecycle', 'gateway', 'mesh', 'microservices'],
        'devops': ['devops', 'ci/cd', 'deployment', 'automation', 'infrastructure'],
        'governance': ['governance', 'compliance', 'policy', 'audit', 'framework'],
        'cloud': ['cloud', 'kubernetes', 'containers', 'serverless', 'infrastructure'],
        'prompt_engineering': ['prompt', 'engineering', 'langchain', 'rag', 'fine-tuning'],
        'productivity': ['productivity', 'workflow', 'efficiency', 'optimization']
    }
}

def extract_text_from_pdf(pdf_path):
    """Extract text content from a PDF file."""
    try:
        reader = PdfReader(pdf_path)
        text = ""
        for page in reader.pages[:10]:  # First 10 pages for analysis
            text += page.extract_text() or ""
        return text.lower()
    except Exception as e:
        return ""

def analyze_relevance(text, filename):
    """Analyze if the PDF content is relevant to commit-relay upgrades."""
    filename_lower = filename.lower()

    # Score relevance based on keyword matches
    scores = {}
    for category, keywords in COMMIT_RELAY_CONTEXT['upgrade_keywords'].items():
        score = sum(1 for kw in keywords if kw in text or kw in filename_lower)
        if score > 0:
            scores[category] = score

    if not scores:
        return None, None

    # Get primary category
    primary_category = max(scores, key=scores.get)
    total_score = sum(scores.values())

    # Threshold for relevance
    if total_score < 2:
        return None, None

    return primary_category, scores

def generate_implementation_prompt(filename, category, text):
    """Generate an implementation prompt based on the PDF content."""

    # Extract key concepts from text
    concepts = []

    # Common patterns to extract
    patterns = [
        r'best practices?',
        r'key (?:features?|benefits?|capabilities?)',
        r'implementation',
        r'architecture',
        r'strategy',
        r'framework'
    ]

    for pattern in patterns:
        if re.search(pattern, text):
            concepts.append(pattern.replace(r'?', '').replace('\\', ''))

    # Category-specific prompts
    prompts = {
        'ai_agents': f"""# AI Agent Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document contains insights on AI agent capabilities that could enhance commit-relay's multi-agent orchestration system.

## Potential Upgrade Paths

### 1. Enhanced Agent Reasoning
- Implement more sophisticated reasoning chains for task planning
- Add reflection and self-correction capabilities to workers
- Improve goal decomposition strategies

### 2. Agent Communication Patterns
- Enhance inter-agent message passing
- Implement shared memory or blackboard patterns
- Add negotiation protocols between masters

### 3. Autonomous Decision Making
- Improve MoE routing with learned preferences
- Add context-aware task allocation
- Implement adaptive strategy selection

## Implementation Considerations
- Integrate with existing master/worker architecture
- Ensure compatibility with token budget system
- Add observability for new agent behaviors

## Priority: HIGH
This directly enhances core commit-relay functionality.
""",

        'observability': f"""# Observability Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document provides insights on observability practices that could improve commit-relay's monitoring capabilities.

## Potential Upgrade Paths

### 1. Enhanced Distributed Tracing
- Extend current trace.sh with more span types
- Add trace sampling strategies
- Implement trace aggregation and analysis

### 2. Metrics Enrichment
- Add custom dimensions to existing metrics
- Implement percentile calculations
- Create alerting rules based on anomalies

### 3. Log Correlation
- Correlate logs with traces
- Add structured logging throughout
- Implement log-based anomaly detection

## Implementation Considerations
- Build on existing scripts/lib/observability/
- Integrate with dashboard on port 3000
- Consider data retention and storage

## Priority: HIGH
Observability is critical for system reliability.
""",

        'security': f"""# Security Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document contains security practices and threat management strategies applicable to commit-relay.

## Potential Upgrade Paths

### 1. Threat Detection Enhancement
- Improve security-master scanning capabilities
- Add behavioral anomaly detection
- Implement threat intelligence feeds

### 2. Incident Response Automation
- Create automated remediation playbooks
- Add incident classification and prioritization
- Implement automated containment actions

### 3. Compliance Monitoring
- Add compliance checking to worker tasks
- Implement policy-as-code validation
- Create audit trails for all operations

## Implementation Considerations
- Extend security-master agent capabilities
- Add to governance framework
- Integrate with anomaly-detector-daemon

## Priority: HIGH
Security is essential for production systems.
""",

        'data_management': f"""# Data Management Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document provides data management and analytics insights for improving commit-relay's data handling.

## Potential Upgrade Paths

### 1. Enhanced Analytics
- Add data warehouse capabilities for metrics
- Implement trend analysis and forecasting
- Create executive dashboards

### 2. Data Governance
- Implement data lineage tracking
- Add data quality monitoring
- Create data catalog for system artifacts

### 3. Pipeline Optimization
- Improve RAG document processing
- Add data validation stages
- Implement incremental processing

## Implementation Considerations
- Build on existing RAG pipeline
- Integrate with coordination data stores
- Consider data retention policies

## Priority: MEDIUM
Enhances operational insights.
""",

        'api_management': f"""# API Management Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document covers API lifecycle management practices applicable to commit-relay's service architecture.

## Potential Upgrade Paths

### 1. API Gateway
- Add rate limiting for dashboard APIs
- Implement API versioning
- Add authentication/authorization

### 2. Service Mesh
- Implement service discovery for daemons
- Add circuit breakers for resilience
- Create traffic management policies

### 3. API Documentation
- Generate OpenAPI specs for all endpoints
- Add API testing automation
- Implement contract testing

## Implementation Considerations
- Enhance dashboard/server/index.js
- Add to existing API endpoints
- Consider backwards compatibility

## Priority: MEDIUM
Improves system interfaces and reliability.
""",

        'governance': f"""# Governance Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document provides governance frameworks and compliance practices for AI systems.

## Potential Upgrade Paths

### 1. Policy Framework
- Implement policy-as-code for agent behavior
- Add approval workflows for sensitive operations
- Create governance dashboards

### 2. Audit and Compliance
- Enhance audit logging in governance files
- Add compliance reporting
- Implement regulatory framework support

### 3. Risk Management
- Add risk scoring to task routing
- Implement risk-based resource allocation
- Create risk mitigation automation

## Implementation Considerations
- Extend coordination/governance/ structure
- Integrate with existing audit logs
- Add to dashboard monitoring

## Priority: MEDIUM
Important for enterprise adoption.
""",

        'devops': f"""# DevOps Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document covers DevOps and CI/CD practices for improving commit-relay's automation capabilities.

## Potential Upgrade Paths

### 1. CI/CD Improvements
- Enhance cicd-master capabilities
- Add deployment strategies (blue-green, canary)
- Implement automated rollbacks

### 2. Infrastructure Automation
- Add infrastructure-as-code support
- Implement environment management
- Create self-service provisioning

### 3. Release Management
- Add release orchestration
- Implement feature flags
- Create release analytics

## Implementation Considerations
- Extend cicd-master agent
- Add to existing scripts/daemons/
- Integrate with git workflows

## Priority: MEDIUM
Enhances automation capabilities.
""",

        'cloud': f"""# Cloud Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document covers cloud architecture and infrastructure practices.

## Potential Upgrade Paths

### 1. Cloud-Native Architecture
- Add containerization support
- Implement Kubernetes deployment
- Create cloud-agnostic abstractions

### 2. Scalability
- Add horizontal scaling for workers
- Implement auto-scaling policies
- Create distributed coordination

### 3. Resilience
- Add multi-region support
- Implement disaster recovery
- Create backup automation

## Implementation Considerations
- Design for cloud deployment
- Consider hybrid scenarios
- Add cloud provider integrations

## Priority: LOW
Future consideration for scale.
""",

        'prompt_engineering': f"""# Prompt Engineering Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document covers prompt engineering and LLM optimization techniques.

## Potential Upgrade Paths

### 1. Prompt Optimization
- Implement prompt templates for agents
- Add few-shot examples to prompts
- Create prompt versioning and A/B testing

### 2. RAG Enhancement
- Improve document chunking strategies
- Add semantic search capabilities
- Implement query optimization

### 3. Chain-of-Thought
- Add reasoning traces to worker outputs
- Implement step-by-step verification
- Create explanation generation

## Implementation Considerations
- Enhance existing RAG pipeline
- Add to worker prompt generation
- Integrate with learning system

## Priority: HIGH
Directly improves agent performance.
""",

        'productivity': f"""# Productivity Enhancement for Commit-Relay

## Source Document
{filename}

## Overview
This document covers productivity and workflow optimization techniques.

## Potential Upgrade Paths

### 1. Workflow Automation
- Add workflow templates for common tasks
- Implement task batching
- Create smart scheduling

### 2. User Experience
- Improve dashboard usability
- Add quick actions and shortcuts
- Create personalized views

### 3. Efficiency Metrics
- Track developer productivity
- Measure automation ROI
- Create efficiency reports

## Implementation Considerations
- Enhance dashboard components
- Add to existing metrics
- Integrate with learning system

## Priority: LOW
Nice-to-have improvements.
"""
    }

    return prompts.get(category, prompts['ai_agents'])

def create_prompt_pdf(output_path, title, content):
    """Create a PDF document with the implementation prompt."""
    doc = SimpleDocTemplate(
        str(output_path),
        pagesize=letter,
        rightMargin=72,
        leftMargin=72,
        topMargin=72,
        bottomMargin=72
    )

    styles = getSampleStyleSheet()

    # Custom styles
    title_style = ParagraphStyle(
        'CustomTitle',
        parent=styles['Heading1'],
        fontSize=16,
        spaceAfter=30
    )

    body_style = ParagraphStyle(
        'CustomBody',
        parent=styles['Normal'],
        fontSize=10,
        leading=14,
        spaceAfter=12
    )

    heading_style = ParagraphStyle(
        'CustomHeading',
        parent=styles['Heading2'],
        fontSize=12,
        spaceBefore=20,
        spaceAfter=10
    )

    story = []

    # Process content
    lines = content.split('\n')
    for line in lines:
        if line.startswith('# '):
            story.append(Paragraph(line[2:], title_style))
        elif line.startswith('## '):
            story.append(Paragraph(line[3:], heading_style))
        elif line.startswith('### '):
            story.append(Paragraph(f"<b>{line[4:]}</b>", body_style))
        elif line.strip():
            # Convert markdown-style formatting
            text = line.replace('**', '<b>').replace('*', '<i>')
            if text.startswith('- '):
                text = f"• {text[2:]}"
            story.append(Paragraph(text, body_style))
        else:
            story.append(Spacer(1, 6))

    doc.build(story)

def main():
    library_dir = Path('/Users/ryandahlberg/commit-relay/library')
    input_dir = library_dir / 'unread'
    output_dir = library_dir / 'processed'

    output_dir.mkdir(parents=True, exist_ok=True)

    # Find all PDF files
    pdf_files = list(input_dir.glob('*.pdf'))

    if not pdf_files:
        print("No PDF files found in library/unread/")
        return

    print(f"Found {len(pdf_files)} PDF files to analyze\n")

    relevant_count = 0
    processed_count = 0

    for pdf_path in sorted(pdf_files):
        filename = pdf_path.name
        print(f"Analyzing: {filename}")

        # Extract text
        text = extract_text_from_pdf(pdf_path)

        if not text:
            print(f"  ⚠ Could not extract text, skipping\n")
            continue

        # Analyze relevance
        category, scores = analyze_relevance(text, filename)

        if category:
            relevant_count += 1
            print(f"  Category: {category}")
            print(f"  Relevance scores: {scores}")

            # Generate implementation prompt
            prompt_content = generate_implementation_prompt(filename, category, text)

            # Create output filename
            base_name = pdf_path.stem
            output_filename = f"UPGRADE-{category.upper()}-{base_name[:50]}.pdf"
            output_path = output_dir / output_filename

            # Create prompt PDF
            try:
                create_prompt_pdf(output_path, f"Upgrade Path: {category}", prompt_content)
                print(f"  ✓ Created: {output_filename}")

                # Delete original
                pdf_path.unlink()
                print(f"  ✓ Deleted original\n")
                processed_count += 1

            except Exception as e:
                print(f"  ✗ Error creating PDF: {e}\n")
        else:
            print(f"  ○ Not relevant to commit-relay upgrades")
            # Delete non-relevant files
            pdf_path.unlink()
            print(f"  ✓ Deleted (not relevant)\n")
            processed_count += 1

    # Summary
    print("=" * 50)
    print("SUMMARY")
    print(f"Files analyzed: {len(pdf_files)}")
    print(f"Relevant upgrade paths found: {relevant_count}")
    print(f"Files processed: {processed_count}")

if __name__ == '__main__':
    main()
