## Sidebar file tree: build, flatten, navigate

import std/[os, algorithm]
import types

proc buildTree*(dirPath: string, depth: int = 0): FileNode =
  result = FileNode(
    name: extractFilename(dirPath),
    path: dirPath,
    kind: fnkDirectory,
    depth: depth,
    expanded: depth == 0,
  )

  var dirs: seq[string] = @[]
  var files: seq[string] = @[]

  for entry in walkDir(dirPath):
    let basename = extractFilename(entry.path)
    if basename.len > 0 and basename[0] == '.':
      continue
    case entry.kind
    of pcDir:
      dirs.add(entry.path)
    of pcFile:
      files.add(entry.path)
    else:
      discard

  dirs.sort()
  files.sort()

  for d in dirs:
    let child = buildTree(d, depth + 1)
    child.expanded = false
    result.children.add(child)
  for f in files:
    result.children.add(FileNode(
      name: extractFilename(f),
      path: f,
      kind: fnkFile,
      depth: depth + 1,
    ))

proc flattenTree*(node: FileNode, list: var seq[FileNode]) =
  list.add(node)
  if node.kind == fnkDirectory and node.expanded:
    for child in node.children:
      flattenTree(child, list)

proc rebuildFlatList*(sidebar: var SidebarState) =
  sidebar.flatList = @[]
  if sidebar.rootNode != nil:
    for child in sidebar.rootNode.children:
      flattenTree(child, sidebar.flatList)
  if sidebar.flatList.len == 0:
    sidebar.cursorIndex = 0
  elif sidebar.cursorIndex >= sidebar.flatList.len:
    sidebar.cursorIndex = sidebar.flatList.len - 1

proc initSidebar*(rootPath: string = ""): SidebarState =
  let dir = if rootPath.len > 0: rootPath
            else: getCurrentDir()
  result.visible = false
  result.focused = false
  result.width = 30
  result.rootPath = dir
  result.rootNode = buildTree(dir)
  result.cursorIndex = 0
  result.scrollOffset = 0
  rebuildFlatList(result)

proc toggleSidebar*(sidebar: var SidebarState) =
  sidebar.visible = not sidebar.visible
  if sidebar.visible and sidebar.rootNode == nil:
    sidebar.rootNode = buildTree(sidebar.rootPath)
    rebuildFlatList(sidebar)

proc sidebarMoveDown*(sidebar: var SidebarState) =
  if sidebar.cursorIndex < sidebar.flatList.len - 1:
    sidebar.cursorIndex += 1

proc sidebarMoveUp*(sidebar: var SidebarState) =
  if sidebar.cursorIndex > 0:
    sidebar.cursorIndex -= 1

proc sidebarExpandOrOpen*(sidebar: var SidebarState): string =
  ## Returns file path if a file was selected, "" if directory was toggled.
  if sidebar.flatList.len == 0:
    return ""
  let node = sidebar.flatList[sidebar.cursorIndex]
  if node.kind == fnkDirectory:
    if not node.expanded:
      if node.children.len == 0:
        let built = buildTree(node.path, node.depth)
        node.children = built.children
      node.expanded = true
      rebuildFlatList(sidebar)
    else:
      node.expanded = false
      rebuildFlatList(sidebar)
    return ""
  else:
    return node.path

proc sidebarCollapse*(sidebar: var SidebarState) =
  if sidebar.flatList.len == 0:
    return
  let node = sidebar.flatList[sidebar.cursorIndex]
  if node.kind == fnkDirectory and node.expanded:
    node.expanded = false
    rebuildFlatList(sidebar)
  else:
    # Go to parent directory
    for i in countdown(sidebar.cursorIndex - 1, 0):
      if sidebar.flatList[i].kind == fnkDirectory and
         sidebar.flatList[i].depth == node.depth - 1:
        sidebar.cursorIndex = i
        break

proc adjustSidebarScroll*(sidebar: var SidebarState, visibleHeight: int) =
  if visibleHeight <= 0:
    return
  if sidebar.cursorIndex < sidebar.scrollOffset:
    sidebar.scrollOffset = sidebar.cursorIndex
  elif sidebar.cursorIndex >= sidebar.scrollOffset + visibleHeight:
    sidebar.scrollOffset = sidebar.cursorIndex - visibleHeight + 1
