# docs/lessons-learned/02-organizing-tasks-for-parallel-work.md

---

We're working on a big task a little task. The big task is improving quality of this project. The little task is:
- Group tasks by the file they touch to avoid worker collisions.
- Order these groups so upstream code (schemas, contexts, auth) is fixed before downstream code (LiveViews) that depends on it.
- Within each level, prioritize P1 security fixes; do not let dependency purity delay critical bugs.

Your task today is the little task. 

### Directives for Better Results

1.  **Validate Data First**
    *   Run this **BEFORE** spawning agents.
    ```sql
    -- Count open tasks
    SELECT COUNT(*) FROM tasks WHERE status='open';

    -- List distinct file paths for open tasks
    SELECT DISTINCT file_path FROM tasks WHERE status='open' ORDER BY file_path;
    ```
    *   *Lesson Learned:* I trusted the initial status output (103 tasks) when there
      were actually 156. Garbage in, garbage out.

2.  **Mutex Groups: Mechanical, Not Analytical**
    *   Avoid asking an agent to "analyze the codebase for dependencies." This invites
      hallucination. Instead, group by `file_path` directly.
    ```sql
    -- Group by file_path directly
    UPDATE tasks SET mutex_group =
      REPLACE(REPLACE(file_path, 'lib/custyard_web/live/', ''), '.ex', '')
    WHERE file_path LIKE '%_live.ex';
    ```
    *   Manually consolidate edge cases. File path grouping is deterministic;
      dependency analysis is not.

3.  **`exec_order`: Priority-Weighted, Not Pure `tsort`**
    *   The agents treated all tasks equally. A P1 session fixation bug shouldn't
      wait for P3 schema cleanup just because "schemas come before LiveViews."
    *   A weighted `exec_order` formula:
        ```
        exec_order = (dependency_level * 10) - (priority_weight)
        -- P1 = 5, P2 = 2, P3 = 0
        ```
    *   Example: A P1 LiveView task (level 8) gets `80 - 5 = 75`, running
      before P3 schema tasks at `10 - 0 = 10`. Wait, that's backwards.
    *   A better approach:
        ```
        exec_order = (dependency_level * 10) + (3 - priority_weight)
        -- P1 tasks within each level run first
        ```

4.  **Validate Before Accepting**
    *   Ask the agent to output verification queries:
    ```sql
    -- Check if any file_path is in multiple mutex_groups
    SELECT file_path, COUNT(DISTINCT mutex_group)
    FROM tasks GROUP BY file_path HAVING COUNT(DISTINCT mutex_group) > 1;

    -- Check if any mutex_group spans multiple files (acceptable, but flag it)
    SELECT mutex_group, COUNT(DISTINCT file_path) as files
    FROM tasks GROUP BY mutex_group HAVING files > 3;
    ```

5.  **Single-Purpose Agents**
    *   Instead of "analyze and produce SQL," split the tasks:
        *   **Agent A:** "List all unique `file_path`s and suggest `mutex_group` names"
          (read-only).
        *   **Me:** Review, adjust, and write the `UPDATE` statements.
        *   **Agent B:** "Given these `mutex_group`s, identify which imports which"
          (read-only).
        *   **Me:** Build `exec_order` from the verified dependency list.
    *   The agents did okay work, but I delegated judgment when I should have
      delegated observation. Assign mechanical tasks to agents and decisions to
      the orchestrator.

### Task discovery 

The slash command is /d:work-tasks-db:

```
  /d:work-tasks-db qa-tasks.db --status    # Check task counts
  /d:work-tasks-db qa-tasks.db --shards    # Preview shard distribution
  /d:work-tasks-db qa-tasks.db             # Launch parallel workers
  /d:work-tasks-db qa-tasks.db --agents 6  # Launch with N agents

  The worker script lives at ~/.claude/scripts/task_worker.py with subcommands:
  python3 ~/.claude/scripts/task_worker.py status qa-tasks.db
  python3 ~/.claude/scripts/task_worker.py shards qa-tasks.db --agent-count 4
  python3 ~/.claude/scripts/task_worker.py claim qa-tasks.db --agent-index 0 --agent-count 4
  python3 ~/.claude/scripts/task_worker.py resolve qa-tasks.db --task-id 42 --notes "fixed"
  python3 ~/.claude/scripts/task_worker.py wontfix qa-tasks.db --task-id 99 --notes "out of scope"
```

For help: /help:work-tasks-db.
