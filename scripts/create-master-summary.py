#!/usr/bin/env python3
"""
Create Master Implementation Summary PDF
Consolidates all upgrade prompts into a phased implementation plan.
"""

import os
from pathlib import Path
from datetime import datetime
from pypdf import PdfReader
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, Table, TableStyle
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib import colors
from reportlab.lib.units import inch

# What commit-relay already has implemented
ALREADY_IMPLEMENTED = {
    'Token budget management with atomic operations',
    'Distributed tracing (OpenTelemetry-inspired)',
    'Agent registry and lifecycle management',
    'RAG pipeline for document processing',
    'Anomaly detection daemon',
    'MoE learning loop with hourly cycles',
    'Multi-agent orchestration (5 masters)',
    'Dashboard monitoring on port 3000',
    'Self-healing daemon infrastructure',
    'Structured metrics with dimensions',
    'Goal-based worker planning',
    'Security scanning via security-master',
    'CI/CD automation via cicd-master',
    'Governance audit logging',
    'Worker restart and failure pattern detection'
}

# Items not compatible with commit-relay architecture
NOT_COMPATIBLE = {
    'Kubernetes deployment',  # Current architecture is local/daemon-based
    'Multi-region support',   # Single-node design
    'Serverless functions',   # Daemon-based architecture
    'Container orchestration', # Shell script based
    'Cloud-native service mesh', # Local architecture
    'GraphQL API',  # REST-based dashboard
}

def extract_implementation_items(text):
    """Extract implementation items from PDF text."""
    items = []

    # Look for bullet points and numbered items
    lines = text.split('\n')
    current_section = ""

    for line in lines:
        line = line.strip()

        # Track sections
        if line.startswith('###') or line.startswith('## '):
            current_section = line.replace('#', '').strip()
            continue

        # Extract bullet items
        if line.startswith('•') or line.startswith('-') or line.startswith('*'):
            item = line.lstrip('•-* ').strip()
            if len(item) > 10 and not item.startswith('Build on') and not item.startswith('Integrate with'):
                items.append({
                    'item': item,
                    'section': current_section
                })

    return items

def categorize_item(item_text):
    """Categorize an item as implemented, not compatible, or upgrade."""
    item_lower = item_text.lower()

    # Check if already implemented
    for impl in ALREADY_IMPLEMENTED:
        if any(word in item_lower for word in impl.lower().split()[:3]):
            return 'implemented'

    # Check if not compatible
    for nc in NOT_COMPATIBLE:
        if nc.lower() in item_lower:
            return 'not_compatible'

    return 'upgrade'

def determine_phase(category, item_text):
    """Determine implementation phase based on category and content."""
    item_lower = item_text.lower()

    # Phase 1: Core enhancements (build on existing)
    phase1_keywords = ['enhance', 'improve', 'extend', 'add to existing', 'optimize']

    # Phase 2: New capabilities
    phase2_keywords = ['implement', 'create', 'add new', 'introduce', 'develop']

    # Phase 3: Advanced features
    phase3_keywords = ['advanced', 'sophisticated', 'complex', 'enterprise', 'scale']

    if any(kw in item_lower for kw in phase1_keywords):
        return 1
    elif any(kw in item_lower for kw in phase3_keywords):
        return 3
    else:
        return 2

def create_summary_pdf(output_path, categories, item_counts):
    """Create the master summary PDF."""
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
        'Title',
        parent=styles['Heading1'],
        fontSize=20,
        spaceAfter=30,
        alignment=1  # Center
    )

    subtitle_style = ParagraphStyle(
        'Subtitle',
        parent=styles['Normal'],
        fontSize=12,
        spaceAfter=20,
        alignment=1,
        textColor=colors.grey
    )

    section_style = ParagraphStyle(
        'Section',
        parent=styles['Heading2'],
        fontSize=14,
        spaceBefore=20,
        spaceAfter=10,
        textColor=colors.darkblue
    )

    subsection_style = ParagraphStyle(
        'Subsection',
        parent=styles['Heading3'],
        fontSize=12,
        spaceBefore=15,
        spaceAfter=8
    )

    item_style = ParagraphStyle(
        'Item',
        parent=styles['Normal'],
        fontSize=10,
        leftIndent=20,
        spaceAfter=6
    )

    note_style = ParagraphStyle(
        'Note',
        parent=styles['Normal'],
        fontSize=9,
        textColor=colors.grey,
        leftIndent=30
    )

    story = []

    # Title page
    story.append(Paragraph("Commit-Relay Implementation Roadmap", title_style))
    story.append(Paragraph(f"Generated: {datetime.now().strftime('%Y-%m-%d')}", subtitle_style))
    story.append(Spacer(1, 20))

    # Executive summary
    story.append(Paragraph("Executive Summary", section_style))

    summary_text = f"""
    This document consolidates implementation recommendations from {item_counts['total_files']}
    source documents into a phased roadmap for commit-relay enhancements.
    <br/><br/>
    <b>Total Implementation Items:</b> {item_counts['total_items']}<br/>
    <b>Already Implemented:</b> {item_counts['implemented']} items<br/>
    <b>Upgrade Opportunities:</b> {item_counts['upgrades']} items<br/>
    <b>Not Compatible:</b> {item_counts['not_compatible']} items
    """
    story.append(Paragraph(summary_text, styles['Normal']))
    story.append(Spacer(1, 20))

    # Priority overview table
    story.append(Paragraph("Implementation Phases Overview", subsection_style))

    phase_data = [
        ['Phase', 'Focus', 'Items', 'Priority'],
        ['Phase 1', 'Core Enhancements', str(len(categories['phase1'])), 'HIGH'],
        ['Phase 2', 'New Capabilities', str(len(categories['phase2'])), 'MEDIUM'],
        ['Phase 3', 'Advanced Features', str(len(categories['phase3'])), 'LOW'],
    ]

    table = Table(phase_data, colWidths=[1*inch, 2*inch, 1*inch, 1*inch])
    table.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), colors.darkblue),
        ('TEXTCOLOR', (0, 0), (-1, 0), colors.whitesmoke),
        ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
        ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
        ('FONTSIZE', (0, 0), (-1, 0), 10),
        ('BOTTOMPADDING', (0, 0), (-1, 0), 12),
        ('BACKGROUND', (0, 1), (-1, -1), colors.beige),
        ('GRID', (0, 0), (-1, -1), 1, colors.black),
    ]))
    story.append(table)
    story.append(PageBreak())

    # Already Implemented Section
    story.append(Paragraph("Already Implemented", section_style))
    story.append(Paragraph(
        "These capabilities are already present in commit-relay. No action required.",
        note_style
    ))
    story.append(Spacer(1, 10))

    for item in sorted(categories['implemented']):
        story.append(Paragraph(f"✓ {item}", item_style))

    story.append(PageBreak())

    # Phase 1: Core Enhancements
    story.append(Paragraph("Phase 1: Core Enhancements", section_style))
    story.append(Paragraph(
        "Build on existing infrastructure. Low risk, high value improvements.",
        note_style
    ))
    story.append(Spacer(1, 10))

    # Group by category
    phase1_by_cat = {}
    for item in categories['phase1']:
        cat = item.get('category', 'General')
        if cat not in phase1_by_cat:
            phase1_by_cat[cat] = []
        phase1_by_cat[cat].append(item['item'])

    for cat in sorted(phase1_by_cat.keys()):
        story.append(Paragraph(cat.replace('_', ' ').title(), subsection_style))
        for item in phase1_by_cat[cat]:
            story.append(Paragraph(f"• {item}", item_style))

    story.append(PageBreak())

    # Phase 2: New Capabilities
    story.append(Paragraph("Phase 2: New Capabilities", section_style))
    story.append(Paragraph(
        "New features and integrations. Moderate complexity.",
        note_style
    ))
    story.append(Spacer(1, 10))

    phase2_by_cat = {}
    for item in categories['phase2']:
        cat = item.get('category', 'General')
        if cat not in phase2_by_cat:
            phase2_by_cat[cat] = []
        phase2_by_cat[cat].append(item['item'])

    for cat in sorted(phase2_by_cat.keys()):
        story.append(Paragraph(cat.replace('_', ' ').title(), subsection_style))
        for item in phase2_by_cat[cat]:
            story.append(Paragraph(f"• {item}", item_style))

    story.append(PageBreak())

    # Phase 3: Advanced Features
    story.append(Paragraph("Phase 3: Advanced Features", section_style))
    story.append(Paragraph(
        "Complex enhancements for scale and enterprise needs. Future consideration.",
        note_style
    ))
    story.append(Spacer(1, 10))

    phase3_by_cat = {}
    for item in categories['phase3']:
        cat = item.get('category', 'General')
        if cat not in phase3_by_cat:
            phase3_by_cat[cat] = []
        phase3_by_cat[cat].append(item['item'])

    for cat in sorted(phase3_by_cat.keys()):
        story.append(Paragraph(cat.replace('_', ' ').title(), subsection_style))
        for item in phase3_by_cat[cat]:
            story.append(Paragraph(f"• {item}", item_style))

    story.append(PageBreak())

    # Not Compatible Section
    story.append(Paragraph("Not Compatible", section_style))
    story.append(Paragraph(
        "These items are not compatible with commit-relay's current architecture.",
        note_style
    ))
    story.append(Spacer(1, 10))

    for item in sorted(categories['not_compatible']):
        story.append(Paragraph(f"✗ {item}", item_style))

    # Build PDF
    doc.build(story)

def main():
    library_dir = Path('/Users/ryandahlberg/commit-relay/library')
    processed_dir = library_dir / 'processed'
    output_path = library_dir / 'COMMIT-RELAY-IMPLEMENTATION-ROADMAP.pdf'

    # Find all UPGRADE PDFs
    upgrade_files = list(processed_dir.glob('UPGRADE-*.pdf'))

    if not upgrade_files:
        print("No UPGRADE PDF files found in library/processed/")
        return

    print(f"Processing {len(upgrade_files)} upgrade prompt files\n")

    # Categories for items
    categories = {
        'implemented': set(),
        'phase1': [],
        'phase2': [],
        'phase3': [],
        'not_compatible': set()
    }

    total_items = 0

    for pdf_path in sorted(upgrade_files):
        filename = pdf_path.name
        print(f"Processing: {filename}")

        # Extract category from filename
        parts = filename.split('-')
        if len(parts) >= 2:
            file_category = parts[1].lower()
        else:
            file_category = 'general'

        # Read PDF
        try:
            reader = PdfReader(pdf_path)
            text = ""
            for page in reader.pages:
                text += page.extract_text() or ""

            # Extract items
            items = extract_implementation_items(text)

            for item_data in items:
                item_text = item_data['item']
                total_items += 1

                # Categorize
                cat_type = categorize_item(item_text)

                if cat_type == 'implemented':
                    categories['implemented'].add(item_text)
                elif cat_type == 'not_compatible':
                    categories['not_compatible'].add(item_text)
                else:
                    # Determine phase
                    phase = determine_phase(file_category, item_text)
                    item_entry = {
                        'item': item_text,
                        'category': file_category
                    }

                    if phase == 1:
                        categories['phase1'].append(item_entry)
                    elif phase == 2:
                        categories['phase2'].append(item_entry)
                    else:
                        categories['phase3'].append(item_entry)

            print(f"  Extracted {len(items)} items")

            # Delete the processed file
            pdf_path.unlink()
            print(f"  ✓ Deleted")

        except Exception as e:
            print(f"  ✗ Error: {e}")

    print(f"\nCreating master summary PDF...")

    # Item counts for summary
    item_counts = {
        'total_files': len(upgrade_files),
        'total_items': total_items,
        'implemented': len(categories['implemented']),
        'upgrades': len(categories['phase1']) + len(categories['phase2']) + len(categories['phase3']),
        'not_compatible': len(categories['not_compatible'])
    }

    # Create the summary PDF
    create_summary_pdf(output_path, categories, item_counts)

    print(f"✓ Created: {output_path.name}")

    # Check if processed folder is empty and delete
    remaining = list(processed_dir.glob('*'))
    remaining = [f for f in remaining if f.name != '.DS_Store']

    if not remaining:
        # Remove .DS_Store if present
        ds_store = processed_dir / '.DS_Store'
        if ds_store.exists():
            ds_store.unlink()
        processed_dir.rmdir()
        print("✓ Deleted empty library/processed folder")
    else:
        print(f"  {len(remaining)} files remain in processed folder")

    # Summary
    print("\n" + "=" * 50)
    print("SUMMARY")
    print(f"Files processed: {len(upgrade_files)}")
    print(f"Total items extracted: {total_items}")
    print(f"  - Already implemented: {len(categories['implemented'])}")
    print(f"  - Phase 1 (Core): {len(categories['phase1'])}")
    print(f"  - Phase 2 (New): {len(categories['phase2'])}")
    print(f"  - Phase 3 (Advanced): {len(categories['phase3'])}")
    print(f"  - Not compatible: {len(categories['not_compatible'])}")
    print(f"\nOutput: library/COMMIT-RELAY-IMPLEMENTATION-ROADMAP.pdf")

if __name__ == '__main__':
    main()
