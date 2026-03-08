"""
Workflow Orchestrator - Multi-task workflows with dependencies.

Orchestrates complex workflows involving multiple tasks with dependencies,
automatically handling execution order and waiting for task completion.
"""

from typing import List, Dict, Callable, Optional, Set
import time
from .task_manager import TaskManager, TaskStatus


class WorkflowOrchestrator:
    """
    Orchestrate multi-task workflows with dependencies.

    The WorkflowOrchestrator allows you to define complex workflows with
    multiple tasks that have dependencies on each other. Tasks are executed
    in the correct order, and the orchestrator waits for dependencies to
    complete before starting dependent tasks.

    Example:
        >>> from commit_relay import CommitRelayClient, TaskManager
        >>> from commit_relay import WorkflowOrchestrator
        >>>
        >>> client = CommitRelayClient()
        >>> manager = TaskManager()
        >>> orchestrator = WorkflowOrchestrator(client, manager)
        >>>
        >>> # Create workflow: scan -> fix -> verify
        >>> workflow = (orchestrator
        ...     .add_task('scan', lambda: manager.create_security_scan(
        ...         repository='ry-ops/test-repo',
        ...         description='Initial security scan'
        ...     ))
        ...     .add_task('fix', lambda: manager.create_security_fix(
        ...         repository='ry-ops/test-repo',
        ...         vulnerabilities=[],
        ...         description='Apply security fixes'
        ...     ), depends_on=['scan'])
        ...     .add_task('verify', lambda: manager.create_security_scan(
        ...         repository='ry-ops/test-repo',
        ...         description='Verify fixes applied'
        ...     ), depends_on=['fix'])
        ... )
        >>>
        >>> # Execute workflow
        >>> task_ids = workflow.execute(poll_interval=5)
        >>> print(f"Workflow completed with tasks: {task_ids}")

    Attributes:
        client: CommitRelayClient instance for API access
        manager: TaskManager instance for task operations
        tasks: List of task definitions with dependencies
    """

    def __init__(self, client, manager: TaskManager):
        """
        Initialize WorkflowOrchestrator.

        Args:
            client: CommitRelayClient instance for monitoring
            manager: TaskManager instance for task creation and status checks
        """
        self.client = client
        self.manager = manager
        self.tasks = []

    def add_task(
        self,
        name: str,
        task_fn: Callable[[], str],
        depends_on: Optional[List[str]] = None
    ):
        """
        Add task to workflow.

        Args:
            name: Unique name for this task in the workflow
            task_fn: Callable that creates and returns a task ID
            depends_on: List of task names this task depends on

        Returns:
            self for method chaining

        Example:
            >>> orchestrator.add_task(
            ...     'scan',
            ...     lambda: manager.create_security_scan(repo='owner/repo')
            ... )
        """
        self.tasks.append({
            'name': name,
            'task_fn': task_fn,
            'depends_on': depends_on or [],
            'task_id': None,
            'completed': False,
            'failed': False
        })
        return self

    def _validate_dependencies(self):
        """
        Validate that all dependencies reference existing tasks.

        Raises:
            ValueError: If a dependency references a non-existent task
        """
        task_names = {task['name'] for task in self.tasks}

        for task_def in self.tasks:
            for dep in task_def['depends_on']:
                if dep not in task_names:
                    raise ValueError(
                        f"Task '{task_def['name']}' depends on "
                        f"non-existent task '{dep}'"
                    )

    def _check_circular_dependencies(self):
        """
        Check for circular dependencies in the workflow.

        Raises:
            ValueError: If circular dependencies are detected
        """
        def has_cycle(task_name: str, visited: Set[str], rec_stack: Set[str]) -> bool:
            visited.add(task_name)
            rec_stack.add(task_name)

            # Find task definition
            task_def = next(t for t in self.tasks if t['name'] == task_name)

            # Check all dependencies
            for dep in task_def['depends_on']:
                if dep not in visited:
                    if has_cycle(dep, visited, rec_stack):
                        return True
                elif dep in rec_stack:
                    return True

            rec_stack.remove(task_name)
            return False

        visited = set()
        rec_stack = set()

        for task_def in self.tasks:
            if task_def['name'] not in visited:
                if has_cycle(task_def['name'], visited, rec_stack):
                    raise ValueError("Circular dependency detected in workflow")

    def execute(
        self,
        poll_interval: int = 10,
        max_retries: int = 3,
        timeout_minutes: int = 120,
        fail_fast: bool = True
    ) -> Dict[str, str]:
        """
        Execute workflow with dependency resolution.

        Tasks are created and executed in dependency order. The orchestrator
        polls for task completion and starts dependent tasks when ready.

        Args:
            poll_interval: Seconds to wait between status checks
            max_retries: Maximum retries for failed tasks
            timeout_minutes: Maximum workflow execution time
            fail_fast: Stop workflow on first task failure

        Returns:
            Dictionary mapping task names to task IDs

        Raises:
            ValueError: If workflow validation fails
            TimeoutError: If workflow exceeds timeout
            RuntimeError: If tasks fail and fail_fast is True

        Example:
            >>> task_ids = orchestrator.execute(poll_interval=5, timeout_minutes=60)
            >>> print(f"Scan task ID: {task_ids['scan']}")
            >>> print(f"Fix task ID: {task_ids['fix']}")
        """
        # Validate workflow
        self._validate_dependencies()
        self._check_circular_dependencies()

        completed_tasks = set()
        failed_tasks = set()
        task_ids = {}
        task_retries = {task['name']: 0 for task in self.tasks}

        start_time = time.time()
        timeout_seconds = timeout_minutes * 60

        print(f"Starting workflow with {len(self.tasks)} tasks...")
        print(f"Timeout: {timeout_minutes} minutes")
        print(f"Poll interval: {poll_interval} seconds")
        print()

        while len(completed_tasks) + len(failed_tasks) < len(self.tasks):
            # Check timeout
            elapsed = time.time() - start_time
            if elapsed > timeout_seconds:
                raise TimeoutError(
                    f"Workflow exceeded timeout of {timeout_minutes} minutes"
                )

            for task_def in self.tasks:
                task_name = task_def['name']

                # Skip if already completed or failed
                if task_def['completed'] or task_def['failed']:
                    continue

                # Check dependencies
                deps_met = all(dep in completed_tasks for dep in task_def['depends_on'])
                if not deps_met:
                    continue

                # Check if any dependency failed
                if fail_fast and any(dep in failed_tasks for dep in task_def['depends_on']):
                    print(f"[{task_name}] Skipping due to failed dependency")
                    task_def['failed'] = True
                    failed_tasks.add(task_name)
                    continue

                # Create task if not yet created
                if task_def['task_id'] is None:
                    try:
                        print(f"[{task_name}] Creating task...")
                        task_def['task_id'] = task_def['task_fn']()
                        task_ids[task_name] = task_def['task_id']
                        print(f"[{task_name}] Created task ID: {task_def['task_id']}")
                    except Exception as e:
                        print(f"[{task_name}] Error creating task: {e}")
                        task_def['failed'] = True
                        failed_tasks.add(task_name)
                        if fail_fast:
                            raise RuntimeError(f"Task creation failed: {task_name}") from e
                        continue

                # Check if completed
                try:
                    task = self.manager.get_task(task_def['task_id'])
                    if task:
                        status = task['status']

                        if status == TaskStatus.COMPLETED.value:
                            print(f"[{task_name}] Task completed ({task_def['task_id']})")
                            task_def['completed'] = True
                            completed_tasks.add(task_name)

                        elif status == TaskStatus.FAILED.value:
                            print(f"[{task_name}] Task failed ({task_def['task_id']})")

                            # Retry if under max_retries
                            if task_retries[task_name] < max_retries:
                                task_retries[task_name] += 1
                                print(f"[{task_name}] Retrying (attempt {task_retries[task_name]}/{max_retries})...")
                                task_def['task_id'] = None  # Reset to create new task
                            else:
                                print(f"[{task_name}] Max retries exceeded")
                                task_def['failed'] = True
                                failed_tasks.add(task_name)
                                if fail_fast:
                                    raise RuntimeError(f"Task failed after {max_retries} retries: {task_name}")

                        elif status == TaskStatus.IN_PROGRESS.value:
                            # Still running, just note it
                            pass

                except Exception as e:
                    print(f"[{task_name}] Error checking status: {e}")

            # Sleep before next poll
            time.sleep(poll_interval)

        print()
        print("=" * 60)
        print("Workflow Execution Summary")
        print("=" * 60)
        print(f"Total tasks: {len(self.tasks)}")
        print(f"Completed: {len(completed_tasks)}")
        print(f"Failed: {len(failed_tasks)}")
        print(f"Execution time: {elapsed:.1f} seconds")
        print()

        if failed_tasks:
            print("Failed tasks:")
            for task_name in failed_tasks:
                task_id = task_ids.get(task_name, 'N/A')
                print(f"  - {task_name} (ID: {task_id})")
            print()

        if completed_tasks:
            print("Completed tasks:")
            for task_name in completed_tasks:
                print(f"  - {task_name} (ID: {task_ids[task_name]})")
            print()

        return task_ids

    def reset(self):
        """
        Reset workflow to initial state.

        Clears all tasks and execution state. Useful for reusing the
        orchestrator instance.

        Returns:
            self for method chaining
        """
        self.tasks = []
        return self
