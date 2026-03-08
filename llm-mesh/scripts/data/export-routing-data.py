#!/usr/bin/env python3
"""
Export historical routing decisions for training
"""

import json
import pandas as pd
from pathlib import Path
from datetime import datetime

def export_routing_data():
    """Export routing decisions to training format"""
    
    # Paths
    source = Path("coordination/masters/coordinator/knowledge-base/routing-decisions.jsonl")
    output_dir = Path("llm-mesh/training-data/routing")
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Read routing decisions with error handling
    decisions = []
    if source.exists():
        with open(source, 'r') as f:
            for i, line in enumerate(f, 1):
                if line.strip():
                    try:
                        decisions.append(json.loads(line))
                    except json.JSONDecodeError as e:
                        print(f"⚠️  Skipping line {i}: {e}")
                        continue
    
    print(f"📊 Found {len(decisions)} valid routing decisions")
    
    if len(decisions) > 0:
        df = pd.DataFrame(decisions)
        output_file = output_dir / "decisions.parquet"
        df.to_parquet(output_file)
        print(f"✅ Exported to {output_file}")
    else:
        print("⚠️  No routing decisions found - creating synthetic data")
        
        # Create synthetic data for demonstration
        synthetic = pd.DataFrame({
            "task_description": [
                "Fix authentication bug in login system",
                "Scan repository for CVE vulnerabilities", 
                "Document API endpoints and usage",
                "Deploy new feature to production",
                "Implement user registration feature",
                "Update dependencies and run security audit",
                "Create comprehensive test suite",
                "Optimize database query performance"
            ],
            "selected_master": [
                "development-master",
                "security-master",
                "inventory-master",
                "cicd-master",
                "development-master",
                "security-master",
                "development-master",
                "development-master"
            ],
            "outcome": ["success"] * 8,
            "confidence": [0.9, 0.95, 0.85, 0.92, 0.88, 0.93, 0.87, 0.91]
        })
        
        synthetic.to_parquet(output_dir / "decisions.parquet")
        print(f"✅ Created synthetic training data with {len(synthetic)} samples")

if __name__ == "__main__":
    export_routing_data()
