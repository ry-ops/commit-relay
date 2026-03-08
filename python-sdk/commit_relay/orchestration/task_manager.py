"""
Task Manager - Programmatic task creation and management.

Provides APIs to create, update, and query tasks in the commit-relay system.
"""

from typing import Optional, Dict, List, Any
from datetime import datetime
from enum import Enum
import json
import subprocess
import os


class TaskType(Enum):
    """Task type enumeration."""
    SECURITY_SCAN = "security-scan"
    SECURITY_FIX = "security-fix"
    DEVELOPMENT = "development"
    CATALOG = "catalog"


class TaskPriority(Enum):
    """Task priority enumeration."""
    CRITICAL = "critical"
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class TaskStatus(Enum):
    """Task status enumeration."""
    PENDING = "pending"
    IN_PROGRESS = "in-progress"
    COMPLETED = "completed"
    FAILED = "failed"


class TaskManager:
    """
    Programmatic task creation and management.

    The TaskManager provides a Python API for creating and managing tasks
    in the commit-relay system. Tasks are automatically picked up by the
    worker daemon for execution.

    Example:
        >>> manager = TaskManager(commit_relay_home='/path/to/commit-relay')
        >>> task_id = manager.create_security_scan(
        ...     repository='ry-ops/mcp-server-unifi',
        ...     priority=TaskPriority.HIGH
        ... )
        >>> print(f"Created task: {task_id}")
        Created task: task-025

    Attributes:
        commit_relay_home: Path to commit-relay repository
        auto_commit: Whether to automatically commit and push changes
        task_queue_path: Path to task-queue.json file
    """

    def __init__(
        self,
        commit_relay_home: str = '/Users/ryandahlberg/commit-relay',
        auto_commit: bool = True
    ):
        """
        Initialize TaskManager.

        Args:
            commit_relay_home: Path to commit-relay repository root
            auto_commit: Whether to automatically commit and push changes to git
        """
        self.commit_relay_home = os.path.expanduser(commit_relay_home)
        self.auto_commit = auto_commit
        self.task_queue_path = os.path.join(
            self.commit_relay_home,
            'coordination',
            'task-queue.json'
        )

        # Validate paths exist
        if not os.path.exists(self.commit_relay_home):
            raise ValueError(f"commit_relay_home does not exist: {self.commit_relay_home}")
        if not os.path.exists(self.task_queue_path):
            raise ValueError(f"task_queue_path does not exist: {self.task_queue_path}")

    def _load_task_queue(self) -> Dict:
        """
        Load current task queue from JSON file.

        Returns:
            Task queue dictionary
        """
        with open(self.task_queue_path, 'r') as f:
            return json.load(f)

    def _save_task_queue(self, queue: Dict):
        """
        Save task queue to JSON file.

        Args:
            queue: Task queue dictionary to save
        """
        queue['updated_at'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        with open(self.task_queue_path, 'w') as f:
            json.dump(queue, f, indent=2)

    def _generate_task_id(self) -> str:
        """
        Generate next sequential task ID.

        Finds the highest existing task number and increments by 1.

        Returns:
            Next task ID in format 'task-XXX' (e.g., 'task-025')
        """
        queue = self._load_task_queue()

        # Find highest task number
        highest = 0
        for task in queue.get('tasks', []):
            task_id = task['id']
            # Extract number from 'task-XXX' format
            try:
                task_num = int(task_id.replace('task-', ''))
                if task_num > highest:
                    highest = task_num
            except (ValueError, AttributeError):
                continue

        next_num = highest + 1
        return f"task-{next_num:03d}"

    def _commit_and_push(self, task_id: str, description: str):
        """
        Commit and push changes to git.

        Args:
            task_id: Task ID for commit message
            description: Task description for commit message
        """
        if not self.auto_commit:
            return

        try:
            # Add task-queue.json
            subprocess.run(
                ['git', 'add', self.task_queue_path],
                cwd=self.commit_relay_home,
                check=True,
                capture_output=True
            )

            # Commit with descriptive message
            commit_msg = f'task: create {task_id} - {description}'
            subprocess.run(
                ['git', 'commit', '-m', commit_msg],
                cwd=self.commit_relay_home,
                check=True,
                capture_output=True
            )

            # Push to origin main
            subprocess.run(
                ['git', 'push', 'origin', 'main'],
                cwd=self.commit_relay_home,
                check=True,
                capture_output=True
            )

        except subprocess.CalledProcessError as e:
            print(f"Warning: Git operations failed: {e}")
            print(f"stderr: {e.stderr.decode() if e.stderr else 'N/A'}")

    def create_task(
        self,
        title: str,
        task_type: TaskType,
        context: Dict[str, Any],
        priority: TaskPriority = TaskPriority.HIGH,
        created_by: str = "python-sdk"
    ) -> str:
        """
        Create a new task.

        This is the low-level task creation method. For specific task types,
        use the convenience methods like create_security_scan(), etc.

        Args:
            title: Task title
            task_type: Type of task (TaskType enum)
            context: Task-specific context dictionary
            priority: Task priority (TaskPriority enum)
            created_by: Source of task creation

        Returns:
            Generated task ID (e.g., 'task-025')

        Example:
            >>> context = {
            ...     'repository': 'owner/repo',
            ...     'branch': 'main',
            ...     'description': 'Security scan',
            ...     'scan_types': ['dependencies', 'secrets']
            ... }
            >>> task_id = manager.create_task(
            ...     title='Security scan for repo',
            ...     task_type=TaskType.SECURITY_SCAN,
            ...     context=context,
            ...     priority=TaskPriority.HIGH
            ... )
        """
        queue = self._load_task_queue()
        task_id = self._generate_task_id()

        task = {
            'id': task_id,
            'title': title,
            'type': task_type.value,
            'priority': priority.value,
            'status': TaskStatus.PENDING.value,
            'assigned_to': None,
            'created_at': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
            'created_by': created_by,
            'context': context
        }

        queue['tasks'].append(task)
        self._save_task_queue(queue)
        self._commit_and_push(task_id, title)

        return task_id

    def create_security_scan(
        self,
        repository: str,
        branch: str = 'main',
        scan_types: List[str] = None,
        priority: TaskPriority = TaskPriority.HIGH,
        description: str = None
    ) -> str:
        """
        Create a security scan task.

        Args:
            repository: Repository in format 'owner/repo'
            branch: Branch to scan (default: 'main')
            scan_types: List of scan types. Options: 'dependencies',
                       'static-analysis', 'secrets'. Default: all three.
            priority: Task priority (default: HIGH)
            description: Task description (auto-generated if not provided)

        Returns:
            Generated task ID

        Example:
            >>> task_id = manager.create_security_scan(
            ...     repository='ry-ops/mcp-server-unifi',
            ...     scan_types=['dependencies', 'secrets'],
            ...     priority=TaskPriority.CRITICAL
            ... )
        """
        if scan_types is None:
            scan_types = ['dependencies', 'static-analysis', 'secrets']

        if description is None:
            description = f"Security scan for {repository}"

        context = {
            'repository': repository,
            'branch': branch,
            'description': description,
            'scan_types': scan_types
        }

        return self.create_task(
            title=description,
            task_type=TaskType.SECURITY_SCAN,
            context=context,
            priority=priority
        )

    def create_security_fix(
        self,
        repository: str,
        vulnerabilities: List[Dict],
        branch: str = 'main',
        priority: TaskPriority = TaskPriority.CRITICAL,
        description: str = None
    ) -> str:
        """
        Create a security fix task.

        Args:
            repository: Repository in format 'owner/repo'
            vulnerabilities: List of vulnerability dictionaries to fix
            branch: Branch to apply fixes to (default: 'main')
            priority: Task priority (default: CRITICAL)
            description: Task description (auto-generated if not provided)

        Returns:
            Generated task ID

        Example:
            >>> vulnerabilities = [
            ...     {
            ...         'package': 'lodash',
            ...         'severity': 'high',
            ...         'fix_version': '4.17.21'
            ...     }
            ... ]
            >>> task_id = manager.create_security_fix(
            ...     repository='ry-ops/my-app',
            ...     vulnerabilities=vulnerabilities
            ... )
        """
        if description is None:
            vuln_count = len(vulnerabilities)
            description = f"Security fixes for {repository} ({vuln_count} vulnerabilities)"

        context = {
            'repository': repository,
            'branch': branch,
            'description': description,
            'vulnerabilities': vulnerabilities
        }

        return self.create_task(
            title=description,
            task_type=TaskType.SECURITY_FIX,
            context=context,
            priority=priority
        )

    def create_development_task(
        self,
        repository: str,
        requirements: List[str],
        branch: str = 'main',
        priority: TaskPriority = TaskPriority.MEDIUM,
        description: str = None
    ) -> str:
        """
        Create a development task.

        Args:
            repository: Repository in format 'owner/repo'
            requirements: List of requirements or features to implement
            branch: Branch to work on (default: 'main')
            priority: Task priority (default: MEDIUM)
            description: Task description (auto-generated if not provided)

        Returns:
            Generated task ID

        Example:
            >>> requirements = [
            ...     'Add user authentication',
            ...     'Implement JWT tokens',
            ...     'Add role-based access control'
            ... ]
            >>> task_id = manager.create_development_task(
            ...     repository='ry-ops/my-app',
            ...     requirements=requirements,
            ...     description='Implement authentication system'
            ... )
        """
        if description is None:
            description = f"Development work for {repository}"

        context = {
            'repository': repository,
            'branch': branch,
            'description': description,
            'requirements': requirements
        }

        return self.create_task(
            title=description,
            task_type=TaskType.DEVELOPMENT,
            context=context,
            priority=priority
        )

    def create_catalog_task(
        self,
        repository: str,
        catalog_depth: str = 'deep',
        priority: TaskPriority = TaskPriority.LOW,
        description: str = None
    ) -> str:
        """
        Create a repository catalog task.

        Args:
            repository: Repository in format 'owner/repo'
            catalog_depth: Depth of catalog ('quick' or 'deep')
            priority: Task priority (default: LOW)
            description: Task description (auto-generated if not provided)

        Returns:
            Generated task ID

        Example:
            >>> task_id = manager.create_catalog_task(
            ...     repository='ry-ops/new-repo',
            ...     catalog_depth='deep'
            ... )
        """
        if description is None:
            description = f"Catalog repository {repository}"

        context = {
            'repository': repository,
            'description': description,
            'catalog_depth': catalog_depth
        }

        return self.create_task(
            title=description,
            task_type=TaskType.CATALOG,
            context=context,
            priority=priority
        )

    def get_task(self, task_id: str) -> Optional[Dict]:
        """
        Get task by ID.

        Args:
            task_id: Task ID to retrieve

        Returns:
            Task dictionary or None if not found

        Example:
            >>> task = manager.get_task('task-025')
            >>> print(task['status'])
            pending
        """
        queue = self._load_task_queue()
        for task in queue.get('tasks', []):
            if task['id'] == task_id:
                return task
        return None

    def update_task_status(
        self,
        task_id: str,
        status: TaskStatus,
        auto_commit: bool = None
    ):
        """
        Update task status.

        Args:
            task_id: Task ID to update
            status: New status (TaskStatus enum)
            auto_commit: Override auto_commit setting for this operation

        Example:
            >>> manager.update_task_status('task-025', TaskStatus.COMPLETED)
        """
        queue = self._load_task_queue()
        task_found = False

        for task in queue['tasks']:
            if task['id'] == task_id:
                old_status = task['status']
                task['status'] = status.value
                task_found = True

                # Add completion timestamp if marking as completed
                if status == TaskStatus.COMPLETED and 'completed_at' not in task:
                    task['completed_at'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

                break

        if not task_found:
            raise ValueError(f"Task not found: {task_id}")

        self._save_task_queue(queue)

        # Commit if requested
        if auto_commit is None:
            auto_commit = self.auto_commit

        if auto_commit:
            self._commit_and_push(
                task_id,
                f"Update status to {status.value}"
            )

    def get_tasks_by_status(self, status: TaskStatus) -> List[Dict]:
        """
        Get all tasks with given status.

        Args:
            status: Status to filter by (TaskStatus enum)

        Returns:
            List of task dictionaries

        Example:
            >>> pending_tasks = manager.get_tasks_by_status(TaskStatus.PENDING)
            >>> for task in pending_tasks:
            ...     print(f"{task['id']}: {task['title']}")
        """
        queue = self._load_task_queue()
        return [
            task for task in queue.get('tasks', [])
            if task['status'] == status.value
        ]

    def get_tasks_by_type(self, task_type: TaskType) -> List[Dict]:
        """
        Get all tasks of given type.

        Args:
            task_type: Type to filter by (TaskType enum)

        Returns:
            List of task dictionaries

        Example:
            >>> security_tasks = manager.get_tasks_by_type(TaskType.SECURITY_SCAN)
        """
        queue = self._load_task_queue()
        return [
            task for task in queue.get('tasks', [])
            if task['type'] == task_type.value
        ]

    def get_pending_tasks(self) -> List[Dict]:
        """
        Get all pending tasks.

        Returns:
            List of pending task dictionaries

        Example:
            >>> pending = manager.get_pending_tasks()
            >>> print(f"Found {len(pending)} pending tasks")
        """
        return self.get_tasks_by_status(TaskStatus.PENDING)

    def get_in_progress_tasks(self) -> List[Dict]:
        """
        Get all in-progress tasks.

        Returns:
            List of in-progress task dictionaries
        """
        return self.get_tasks_by_status(TaskStatus.IN_PROGRESS)

    def get_completed_tasks(self) -> List[Dict]:
        """
        Get all completed tasks.

        Returns:
            List of completed task dictionaries
        """
        return self.get_tasks_by_status(TaskStatus.COMPLETED)

    def get_all_tasks(self) -> List[Dict]:
        """
        Get all tasks.

        Returns:
            List of all task dictionaries
        """
        queue = self._load_task_queue()
        return queue.get('tasks', [])

    def delete_task(self, task_id: str, auto_commit: bool = None):
        """
        Delete a task.

        Args:
            task_id: Task ID to delete
            auto_commit: Override auto_commit setting for this operation

        Example:
            >>> manager.delete_task('task-025')
        """
        queue = self._load_task_queue()
        original_length = len(queue['tasks'])

        queue['tasks'] = [
            task for task in queue['tasks']
            if task['id'] != task_id
        ]

        if len(queue['tasks']) == original_length:
            raise ValueError(f"Task not found: {task_id}")

        self._save_task_queue(queue)

        # Commit if requested
        if auto_commit is None:
            auto_commit = self.auto_commit

        if auto_commit:
            self._commit_and_push(task_id, "Delete task")
