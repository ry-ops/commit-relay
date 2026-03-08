"""
Event Management - Single Source of Truth

All events in commit-relay flow through coordination/dashboard-events.jsonl
"""

from .emitter import EventEmitter

__all__ = ['EventEmitter']
