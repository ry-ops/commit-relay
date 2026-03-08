"""
Neural Router - ML-enhanced task routing for MoE system

This module implements a neural network-based router that learns to assign
tasks to the optimal master agent based on task description, context, and
historical performance.
"""

import torch
import torch.nn as nn
import json
from typing import Dict, Tuple, List, Optional
from pathlib import Path


class MoERouterModel(nn.Module):
    """
    Neural network for task-to-master routing
    
    Architecture:
    - Task encoder (BERT-based for text understanding)
    - Context encoder (historical performance features)
    - Attention mechanism (task-master matching)
    - Classifier (5 masters + confidence)
    """
    
    def __init__(
        self,
        embedding_dim: int = 512,
        hidden_dim: int = 256,
        num_masters: int = 5,
        dropout: float = 0.1
    ):
        super().__init__()
        
        # Task text encoder
        self.task_encoder = nn.Sequential(
            nn.Linear(embedding_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, hidden_dim)
        )
        
        # Context encoder (historical features)
        self.context_encoder = nn.Sequential(
            nn.Linear(64, hidden_dim),  # 64 historical features
            nn.ReLU(),
            nn.Dropout(dropout)
        )
        
        # Attention mechanism for task-master matching
        self.attention = nn.MultiheadAttention(
            embed_dim=hidden_dim,
            num_heads=4,
            dropout=dropout
        )
        
        # Classifier
        self.classifier = nn.Sequential(
            nn.Linear(hidden_dim * 2, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, num_masters)
        )
        
        # Confidence predictor
        self.confidence = nn.Sequential(
            nn.Linear(hidden_dim * 2, hidden_dim // 2),
            nn.ReLU(),
            nn.Linear(hidden_dim // 2, 1),
            nn.Sigmoid()
        )
        
        self.num_masters = num_masters
        
    def forward(
        self,
        task_embedding: torch.Tensor,
        context_features: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """
        Forward pass
        
        Args:
            task_embedding: [batch, embedding_dim] - Task description embedding
            context_features: [batch, 64] - Historical context features
            
        Returns:
            logits: [batch, num_masters] - Master selection logits
            confidence: [batch, 1] - Confidence scores
        """
        # Encode task and context
        task_enc = self.task_encoder(task_embedding)
        context_enc = self.context_encoder(context_features)
        
        # Attention mechanism
        task_enc = task_enc.unsqueeze(0)  # [1, batch, hidden]
        context_enc = context_enc.unsqueeze(0)
        attn_output, _ = self.attention(task_enc, context_enc, context_enc)
        attn_output = attn_output.squeeze(0)  # [batch, hidden]
        
        # Combine representations
        combined = torch.cat([task_enc.squeeze(0), attn_output], dim=-1)
        
        # Classify and predict confidence
        logits = self.classifier(combined)
        conf = self.confidence(combined)
        
        return logits, conf


class NeuralRouter:
    """
    Neural router for intelligent task-to-master assignment
    
    This router uses a trained neural network to select the optimal master
    for each task based on learned patterns from historical routing decisions.
    """
    
    MASTER_NAMES = [
        "development-master",
        "security-master",
        "inventory-master",
        "cicd-master",
        "coordinator-master"
    ]
    
    def __init__(
        self,
        model_path: Optional[Path] = None,
        device: str = "cpu"
    ):
        """
        Initialize neural router
        
        Args:
            model_path: Path to trained model checkpoint
            device: Device to run inference on (cpu/cuda)
        """
        self.device = torch.device(device)
        self.model = MoERouterModel().to(self.device)
        self.model.eval()
        
        if model_path and model_path.exists():
            self.load(model_path)
            
    def load(self, model_path: Path):
        """Load trained model from checkpoint"""
        checkpoint = torch.load(model_path, map_location=self.device)
        self.model.load_state_dict(checkpoint['model_state_dict'])
        self.model.eval()
        
    def save(self, model_path: Path):
        """Save model checkpoint"""
        model_path.parent.mkdir(parents=True, exist_ok=True)
        torch.save({
            'model_state_dict': self.model.state_dict(),
            'master_names': self.MASTER_NAMES
        }, model_path)
        
    @torch.no_grad()
    def route(
        self,
        task_description: str,
        task_embedding: torch.Tensor,
        context_features: Optional[torch.Tensor] = None
    ) -> Tuple[str, float, Dict[str, float]]:
        """
        Route task to optimal master
        
        Args:
            task_description: Natural language task description
            task_embedding: Precomputed task embedding [embedding_dim]
            context_features: Historical context features [64]
            
        Returns:
            master_name: Selected master
            confidence: Confidence score (0-1)
            all_probabilities: Probabilities for all masters
        """
        self.model.eval()
        
        # Prepare inputs
        task_emb = task_embedding.unsqueeze(0).to(self.device)
        
        if context_features is None:
            context_features = torch.zeros(1, 64)
        context_feat = context_features.unsqueeze(0).to(self.device)
        
        # Forward pass
        logits, conf = self.model(task_emb, context_feat)
        
        # Get probabilities
        probs = torch.softmax(logits, dim=-1)[0]
        confidence = conf[0].item()
        
        # Select master
        master_idx = probs.argmax().item()
        master_name = self.MASTER_NAMES[master_idx]
        
        # All probabilities
        all_probs = {
            name: prob.item()
            for name, prob in zip(self.MASTER_NAMES, probs)
        }
        
        return master_name, confidence, all_probs
    
    def route_batch(
        self,
        task_embeddings: torch.Tensor,
        context_features: Optional[torch.Tensor] = None
    ) -> List[Tuple[str, float, Dict[str, float]]]:
        """
        Route multiple tasks in batch
        
        Args:
            task_embeddings: [batch, embedding_dim]
            context_features: [batch, 64] or None
            
        Returns:
            List of (master_name, confidence, probabilities) tuples
        """
        self.model.eval()
        
        task_emb = task_embeddings.to(self.device)
        
        if context_features is None:
            context_features = torch.zeros(len(task_emb), 64)
        context_feat = context_features.to(self.device)
        
        # Forward pass
        logits, conf = self.model(task_emb, context_feat)
        probs = torch.softmax(logits, dim=-1)
        
        results = []
        for i in range(len(task_emb)):
            master_idx = probs[i].argmax().item()
            master_name = self.MASTER_NAMES[master_idx]
            confidence = conf[i].item()
            
            all_probs = {
                name: probs[i][j].item()
                for j, name in enumerate(self.MASTER_NAMES)
            }
            
            results.append((master_name, confidence, all_probs))
            
        return results
    
    def explain_routing(
        self,
        task_description: str,
        task_embedding: torch.Tensor,
        context_features: Optional[torch.Tensor] = None
    ) -> Dict:
        """
        Explain routing decision with probabilities and reasoning
        
        Returns detailed explanation of why a particular master was selected
        """
        master_name, confidence, all_probs = self.route(
            task_description, task_embedding, context_features
        )
        
        # Sort masters by probability
        sorted_masters = sorted(
            all_probs.items(),
            key=lambda x: x[1],
            reverse=True
        )
        
        return {
            "selected_master": master_name,
            "confidence": confidence,
            "task_description": task_description,
            "all_probabilities": all_probs,
            "ranking": [
                {"master": m, "probability": p}
                for m, p in sorted_masters
            ],
            "reasoning": self._generate_reasoning(
                master_name, confidence, sorted_masters
            )
        }
    
    def _generate_reasoning(
        self,
        selected_master: str,
        confidence: float,
        sorted_masters: List[Tuple[str, float]]
    ) -> str:
        """Generate human-readable reasoning for routing decision"""
        top_prob = sorted_masters[0][1]
        second_prob = sorted_masters[1][1] if len(sorted_masters) > 1 else 0
        
        reasoning = f"Selected {selected_master} with {confidence:.2%} confidence. "
        
        if top_prob > 0.7:
            reasoning += "High certainty based on strong pattern match."
        elif top_prob > 0.5:
            reasoning += "Moderate certainty. Task characteristics align well."
        else:
            reasoning += "Lower certainty. Task could match multiple masters."
            
        if top_prob - second_prob < 0.1:
            second_master = sorted_masters[1][0]
            reasoning += f" Close second: {second_master} ({second_prob:.2%})."
            
        return reasoning


class EnsembleRouter:
    """
    Ensemble router combining neural model with rule-based fallback
    
    This provides robustness by combining learned routing with traditional
    pattern matching as a fallback when confidence is low.
    """
    
    def __init__(
        self,
        neural_router: NeuralRouter,
        confidence_threshold: float = 0.5
    ):
        self.neural_router = neural_router
        self.confidence_threshold = confidence_threshold
        
    def route(
        self,
        task_description: str,
        task_embedding: torch.Tensor,
        context_features: Optional[torch.Tensor] = None
    ) -> Tuple[str, float, str]:
        """
        Route using ensemble approach
        
        Returns:
            master_name: Selected master
            confidence: Confidence score
            method: Routing method used ("neural" or "fallback")
        """
        # Try neural routing first
        master, conf, probs = self.neural_router.route(
            task_description, task_embedding, context_features
        )
        
        # Use neural if confidence is high enough
        if conf >= self.confidence_threshold:
            return master, conf, "neural"
            
        # Fall back to rule-based routing
        fallback_master = self._rule_based_routing(task_description)
        return fallback_master, conf, "fallback"
        
    def _rule_based_routing(self, task_description: str) -> str:
        """Simple rule-based fallback routing"""
        desc_lower = task_description.lower()
        
        # Pattern matching for keywords
        if any(word in desc_lower for word in ["security", "vulnerability", "cve", "audit"]):
            return "security-master"
        elif any(word in desc_lower for word in ["build", "deploy", "ci/cd", "pipeline"]):
            return "cicd-master"
        elif any(word in desc_lower for word in ["document", "catalog", "inventory"]):
            return "inventory-master"
        elif any(word in desc_lower for word in ["fix", "bug", "implement", "feature"]):
            return "development-master"
        else:
            return "coordinator-master"
