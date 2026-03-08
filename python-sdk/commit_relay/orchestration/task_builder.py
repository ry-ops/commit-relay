"""
Task Builder - Fluent API for building complex tasks.

Provides a chainable interface for task creation with a more expressive syntax.
"""

from typing import List, Dict
from .task_manager import TaskManager, TaskType, TaskPriority


class TaskBuilder:
    """
    Fluent API for building complex tasks.

    The TaskBuilder provides a chainable interface for creating tasks with
    a more expressive syntax. Each method returns self, allowing method chaining.

    Example:
        >>> manager = TaskManager()
        >>> task_id = (TaskBuilder(manager)
        ...            .security_scan()
        ...            .repository('ry-ops/mcp-server-unifi')
        ...            .priority(TaskPriority.CRITICAL)
        ...            .scan_types(['dependencies', 'secrets'])
        ...            .description('Critical security audit')
        ...            .create())
        >>> print(f"Created task: {task_id}")
        Created task: task-025

    Fluent API Example:
        >>> # Create a development task
        >>> task_id = (TaskBuilder(manager)
        ...            .development()
        ...            .repository('owner/repo')
        ...            .branch('feature/new-feature')
        ...            .requirements([
        ...                'Add authentication',
        ...                'Implement JWT'
        ...            ])
        ...            .priority(TaskPriority.HIGH)
        ...            .create())
    """

    def __init__(self, manager: TaskManager):
        """
        Initialize TaskBuilder.

        Args:
            manager: TaskManager instance to use for task creation
        """
        self._manager = manager
        self._task_type = None
        self._repository = None
        self._branch = 'main'
        self._priority = TaskPriority.HIGH
        self._description = None
        self._scan_types = ['dependencies', 'static-analysis', 'secrets']
        self._requirements = []
        self._vulnerabilities = []
        self._catalog_depth = 'deep'

    def security_scan(self):
        """
        Set task type to security scan.

        Returns:
            self for method chaining
        """
        self._task_type = TaskType.SECURITY_SCAN
        return self

    def security_fix(self):
        """
        Set task type to security fix.

        Returns:
            self for method chaining
        """
        self._task_type = TaskType.SECURITY_FIX
        return self

    def development(self):
        """
        Set task type to development.

        Returns:
            self for method chaining
        """
        self._task_type = TaskType.DEVELOPMENT
        return self

    def catalog(self):
        """
        Set task type to catalog.

        Returns:
            self for method chaining
        """
        self._task_type = TaskType.CATALOG
        return self

    def repository(self, repo: str):
        """
        Set repository.

        Args:
            repo: Repository in format 'owner/repo'

        Returns:
            self for method chaining
        """
        self._repository = repo
        return self

    def branch(self, branch: str):
        """
        Set branch.

        Args:
            branch: Branch name

        Returns:
            self for method chaining
        """
        self._branch = branch
        return self

    def priority(self, priority: TaskPriority):
        """
        Set priority.

        Args:
            priority: Task priority (TaskPriority enum)

        Returns:
            self for method chaining
        """
        self._priority = priority
        return self

    def description(self, desc: str):
        """
        Set description.

        Args:
            desc: Task description

        Returns:
            self for method chaining
        """
        self._description = desc
        return self

    def scan_types(self, types: List[str]):
        """
        Set scan types (for security scan tasks).

        Args:
            types: List of scan types ('dependencies', 'static-analysis', 'secrets')

        Returns:
            self for method chaining
        """
        self._scan_types = types
        return self

    def requirements(self, reqs: List[str]):
        """
        Set requirements (for development tasks).

        Args:
            reqs: List of requirements or features to implement

        Returns:
            self for method chaining
        """
        self._requirements = reqs
        return self

    def vulnerabilities(self, vulns: List[Dict]):
        """
        Set vulnerabilities (for security fix tasks).

        Args:
            vulns: List of vulnerability dictionaries

        Returns:
            self for method chaining
        """
        self._vulnerabilities = vulns
        return self

    def catalog_depth(self, depth: str):
        """
        Set catalog depth (for catalog tasks).

        Args:
            depth: Catalog depth ('quick' or 'deep')

        Returns:
            self for method chaining
        """
        self._catalog_depth = depth
        return self

    def create(self) -> str:
        """
        Build and create the task.

        This method validates the configuration and calls the appropriate
        TaskManager method to create the task.

        Returns:
            Generated task ID

        Raises:
            ValueError: If task type is not set or repository is missing
        """
        # Validate required fields
        if self._task_type is None:
            raise ValueError(
                "Task type not set. Call security_scan(), development(), "
                "security_fix(), or catalog() first."
            )

        if self._repository is None:
            raise ValueError("Repository not set. Call repository('owner/repo').")

        # Create task based on type
        if self._task_type == TaskType.SECURITY_SCAN:
            return self._manager.create_security_scan(
                repository=self._repository,
                branch=self._branch,
                scan_types=self._scan_types,
                priority=self._priority,
                description=self._description
            )

        elif self._task_type == TaskType.SECURITY_FIX:
            return self._manager.create_security_fix(
                repository=self._repository,
                vulnerabilities=self._vulnerabilities,
                branch=self._branch,
                priority=self._priority,
                description=self._description
            )

        elif self._task_type == TaskType.DEVELOPMENT:
            return self._manager.create_development_task(
                repository=self._repository,
                requirements=self._requirements,
                branch=self._branch,
                priority=self._priority,
                description=self._description
            )

        elif self._task_type == TaskType.CATALOG:
            return self._manager.create_catalog_task(
                repository=self._repository,
                catalog_depth=self._catalog_depth,
                priority=self._priority,
                description=self._description
            )

        else:
            raise ValueError(f"Unknown task type: {self._task_type}")

    def reset(self):
        """
        Reset builder to default state.

        Useful for reusing the same builder instance to create multiple tasks.

        Returns:
            self for method chaining
        """
        self._task_type = None
        self._repository = None
        self._branch = 'main'
        self._priority = TaskPriority.HIGH
        self._description = None
        self._scan_types = ['dependencies', 'static-analysis', 'secrets']
        self._requirements = []
        self._vulnerabilities = []
        self._catalog_depth = 'deep'
        return self
