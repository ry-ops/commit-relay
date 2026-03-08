#!/usr/bin/env python3
"""
PDF Processing Script
Processes PDFs by removing blank pages, compressing, and optimizing.
"""

import os
import sys
from pathlib import Path
from pypdf import PdfReader, PdfWriter

def is_blank_page(page):
    """Check if a page is essentially blank (very little text content)."""
    try:
        text = page.extract_text()
        # Consider blank if less than 50 characters of actual content
        cleaned = ''.join(text.split())
        return len(cleaned) < 50
    except:
        return False

def process_pdf(input_path, output_path):
    """Process a single PDF file."""
    try:
        reader = PdfReader(input_path)
        writer = PdfWriter()

        original_pages = len(reader.pages)
        kept_pages = 0
        removed_pages = 0

        for i, page in enumerate(reader.pages):
            # Skip blank pages
            if is_blank_page(page):
                removed_pages += 1
                continue

            writer.add_page(page)
            kept_pages += 1

        # If we removed all pages, keep at least the first page
        if kept_pages == 0 and original_pages > 0:
            writer.add_page(reader.pages[0])
            kept_pages = 1
            removed_pages = original_pages - 1

        # Compress the output
        for page in writer.pages:
            page.compress_content_streams()

        # Write the optimized PDF
        with open(output_path, 'wb') as f:
            writer.write(f)

        # Get file sizes for comparison
        original_size = os.path.getsize(input_path)
        new_size = os.path.getsize(output_path)
        reduction = ((original_size - new_size) / original_size) * 100 if original_size > 0 else 0

        return {
            'success': True,
            'original_pages': original_pages,
            'kept_pages': kept_pages,
            'removed_pages': removed_pages,
            'original_size': original_size,
            'new_size': new_size,
            'reduction': reduction
        }

    except Exception as e:
        return {
            'success': False,
            'error': str(e)
        }

def format_size(size_bytes):
    """Format bytes to human readable."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f}TB"

def main():
    library_dir = Path('/Users/ryandahlberg/commit-relay/library')
    input_dir = library_dir / 'new'
    output_dir = library_dir / 'processed'

    # Ensure output directory exists
    output_dir.mkdir(parents=True, exist_ok=True)

    # Find all PDF files
    pdf_files = list(input_dir.glob('*.pdf'))

    if not pdf_files:
        print("No PDF files found in library/new/")
        return

    print(f"Found {len(pdf_files)} PDF files to process\n")

    total_original = 0
    total_new = 0
    processed_count = 0

    for pdf_path in sorted(pdf_files):
        filename = pdf_path.name
        output_path = output_dir / filename

        print(f"Processing: {filename}")

        result = process_pdf(pdf_path, output_path)

        if result['success']:
            total_original += result['original_size']
            total_new += result['new_size']
            processed_count += 1

            print(f"  Pages: {result['original_pages']} -> {result['kept_pages']} (removed {result['removed_pages']})")
            print(f"  Size: {format_size(result['original_size'])} -> {format_size(result['new_size'])} ({result['reduction']:.1f}% reduction)")

            # Delete original
            pdf_path.unlink()
            print(f"  ✓ Processed and original deleted\n")
        else:
            print(f"  ✗ Error: {result['error']}\n")

    # Summary
    print("=" * 50)
    print(f"SUMMARY")
    print(f"Files processed: {processed_count}/{len(pdf_files)}")
    print(f"Total size: {format_size(total_original)} -> {format_size(total_new)}")
    if total_original > 0:
        overall_reduction = ((total_original - total_new) / total_original) * 100
        print(f"Overall reduction: {overall_reduction:.1f}%")

if __name__ == '__main__':
    main()
