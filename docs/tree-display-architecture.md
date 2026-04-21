# Tree Display Architecture: Lessons Learned

How to structure a tree database so it can be rendered in an interactive graph
without freezing the UI. Based on our experience with a 115,000-node chess
opening tree and the `graphview` Flutter package.

---

## The problem

A naively-structured recursive tree (parent pointer + children list) works
fine for algorithms that traverse the whole tree (expectimax, ease, selection).
But graph visualization libraries lay out *every* node on every frame. With
100k+ nodes, this causes:

| Operation             | Time (115k nodes) | Acceptable? |
|-----------------------|-------------------|-------------|
| JSON parse + deser    | ~440ms            | Yes (once)   |
| Graph data build      | **25,000ms**      | No           |
| Layout algorithm      | **hangs**         | No           |
| Widget build (20k)    | **hangs**         | No           |

The root cause: the display layer was doing O(n) work on the *entire* tree
when it only needs to show a few hundred nodes at a time.

---

## Principle 1: Flat index alongside the tree

**Never throw away an index you've already built.**

During deserialization we were building a `Map<int, Node>` to wire up
parent/child pointers, then discarding it. Every consumer that needed
random access by ID had to walk the tree or build its own map.

### What to store

```
BuildTree
├── root: BuildTreeNode          ← recursive tree (algorithms)
├── nodeIndex: Map<int, Node>    ← flat O(1) lookup (display, queries)
├── totalNodes: int
└── maxDepthReached: int
```

### Rules

- **Populate during construction.** Every `_makeChild()` call should
  `tree.registerNode(child)`. Every deserialization pass should keep
  the parse-time map.
- **Remove on prune.** When deleting subtrees, walk the removed nodes
  and `nodeIndex.remove(id)` for each.
- **Rebuild if uncertain.** Provide a `computeMetadata()` that does a
  single DFS to re-populate the index from scratch. Call it on resume
  or after any bulk mutation.

---

## Principle 2: Pre-sort children once, not per-frame

Widget `build()` methods run 60 times per second. Sorting a node's
children list on every frame is wasteful when the sort order only
changes after bulk operations (deserialization, repertoire selection).

### What to do

```dart
void sortAllChildren() {
  _sortRecursive(root);
}
```

Call it:
- At the end of `deserializeTree()`
- After any phase that changes sort-relevant fields (e.g. `isRepertoireMove`,
  `moveProbability`)

Then every consumer can use `node.children` directly instead of copying
and sorting.

### Sort key for chess trees

```
1. isRepertoireMove  DESC   (selected moves first)
2. moveProbability   DESC   (most likely moves first)
```

This means `children[0]` is always the best default "forward" move,
which simplifies navigation code.

---

## Principle 3: Pre-compute subtree metadata

Certain per-node values are expensive to derive on the fly but trivial
to compute in a single bottom-up DFS:

| Field          | Type  | Use                                         |
|----------------|-------|---------------------------------------------|
| `subtreeSize`  | int   | Display budget allocation, skip dead ends   |
| `subtreeDepth` | int   | Already existed; depth of deepest descendant|

### How

```dart
int _metadataRecursive(BuildTreeNode node) {
  nodeIndex[node.nodeId] = node;
  int size = 1;
  for (final child in node.children) {
    size += _metadataRecursive(child);
  }
  node.subtreeSize = size;
  return size;
}
```

Combine with the index rebuild so it's a single pass. For 115k nodes
this takes <50ms.

---

## Principle 4: Focused window, not full render

**Never feed the entire tree to the graph layout engine.** Instead,
render a small window around the user's current position:

```
                   [root]
                     |
               [ancestor 1]  ← spine
              /      |
        [sibling] [ancestor 2]  ← siblings for context
                     |
              [current node]  ← user is here
              /    |     \
          [child] [child] [child]  ← descendants (limited depth)
            |
          [grandchild]
```

### The focused window algorithm

1. **Ancestor spine**: Walk `parent` pointers from current node to root.
   Add all spine nodes and edges.
2. **Sibling context**: For each spine node, add its siblings (other
   children of its parent). These show what alternative branches exist
   at each level.
3. **Descendants**: From the current node, DFS down `maxDescendantDepth`
   levels (we use 4). Children are already pre-sorted so the most
   important branches are added first.
4. **Hard cap**: Stop adding nodes once `maxDisplayNodes` is reached
   (we use 400). This prevents pathological cases.

### Performance

| Tree size | Display nodes | `_rebuildGraph` time |
|-----------|--------------|---------------------|
| 115k      | ~50-200      | <5ms                |
| 500k      | ~50-200      | <5ms                |

The display node count depends on branching factor at the current
position, not on total tree size.

---

## Principle 5: Reset the graph viewer on structural changes

Graph libraries like `graphview` use `InteractiveViewer` for pan/zoom.
When you swap in a completely new graph:

- The old pan/zoom transform points at coordinates from the old layout
- Scrolling moves through empty space
- The view goes blank

### Fix

Force a fresh `GraphView` widget on every graph rebuild by giving it
a key that changes:

```dart
int _graphGeneration = 0;

void _rebuildGraph() {
  _graphGeneration++;
  _graphController = GraphViewController();
  // ... rebuild graph ...
}

// In build():
GraphView.builder(
  key: ValueKey(_graphGeneration),
  // ...
)
```

The changing key tells Flutter to tear down the old `InteractiveViewer`
and create a new one, resetting pan/zoom to center on the new layout.

---

## Summary: ideal tree data model for graph display

```
BuildTree
│
├── root ─────────────── Recursive tree for algorithms
│   └── children[]       Pre-sorted (repertoire first, then probability)
│       └── children[]   Each node has subtreeSize pre-computed
│
├── nodeIndex ────────── Map<int, Node> for O(1) lookup
│                        Populated during build, kept in sync on mutations
│
├── sortAllChildren() ── One-time sort after bulk changes
├── computeMetadata() ── One-time DFS to rebuild index + subtreeSize
│
└── totalNodes ───────── Maintained incrementally
    maxDepthReached
```

### Display widget responsibilities

The graph widget should only:
1. Build a focused window (~200 nodes) around the current selection
2. Create graph nodes/edges for that window
3. Look up node data from `tree.nodeIndex` (not maintain its own map)
4. Use pre-sorted `node.children` directly (not re-sort)
5. Force a fresh graph view on every structural rebuild

### What NOT to do

- Do not feed the whole tree to the layout engine
- Do not sort children on every `build()` frame
- Do not build a separate node map in each widget
- Do not reuse `InteractiveViewer` state across graph replacements
- Do not call `countSubtree()` on demand -- use pre-computed `subtreeSize`
