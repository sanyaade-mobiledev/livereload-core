debug = require('debug')('livereload:core:project')
Path  = require 'path'
Url   = require 'url'
R     = require 'reactive'
urlmatch = require 'urlmatch'
fsmonitor = require 'fsmonitor'

CompilerOptions = require './compileropts'
FileOptions     = require './fileopts'
CompilationAction = require '../rules/compilation-action'

Run      = require '../runs/run'
RuleSet = require '../rules/ruleset'

{ RelPathList, RelPathSpec } = require 'pathspec'


RegExp_escape = (s) ->
  s.replace /// [-/\\^$*+?.()|[\]{}] ///g, '\\$&'


nextId = 1


abspath = (path) ->
  if path.charAt(0) is '~'
    home = process.env.HOME
    if path.length is 1
      home
    else if path.charAt(1) is '/'
      Path.resolve(home, path.substr(2))
    else if m = path.match ///^ ~ ([^/]+) / (.*) $ ///
      other = Path.join(Path.dirname(home), m[1])  # TODO: resolve other users' home folders properly
      Path.resolve(other, m[2])
  else
    Path.resolve(path)


class Rule_Project

  schema:
    project:                  { type: Object }

  'get files': ->
    for path in @project.tree.findMatchingPaths(@action.compiler.sourceFilter)
      @project.fileAt(path)


class Project extends R.Model

  schema:
    compilationEnabled:       { type: Boolean }

    # always do a full page reload
    disableLiveRefresh:       { type: Boolean }

    # enables URL overriding when CSS modifications are detected
    enableRemoteWorkflow:     { type: Boolean }

    # in ms
    fullPageReloadDelay:      { type: Number }
    eventProcessingDelay:     { type: Number }

    rubyVersionId:            { type: String }

    # paths we should never monitor or enumerate
    excludedPaths:            { type: { array: String } }

    # URL wildcards that correspond to this project's files
    urls:                     { type: { array: String } }

    customName:               { type: String }
    nrPathCompsInName:        { type: 'int' }

    snippet:                  { type: String, computed: yes }
    availableCompilers:       { type: Array, computed: yes }

    fileOptionsByPath:        {}

    compilableFilesFilter:    { computed: yes }

    _mixins: [
      [require('../rules/rule').FileToFileRule, [Rule_Project]]
    ]


  initialize: ({ @session, @vfs, @path }) ->
    @name = Path.basename(@path)
    @id = "P#{nextId++}_#{@name}"
    @fullPath = abspath(@path)
    @analyzer = new (require './analyzer')(this)

    @watcher = fsmonitor.watch(@fullPath, null)
    debug "Monitoring for changes: folder = %j", @fullPath
    @watcher.on 'change', (change) =>
      debug "Detected change:\n#{change}"
      @handleChange @vfs, @fullPath, change.addedFiles.concat(change.modifiedFiles)
    @tree = @watcher.tree

    # actions =
    #   for compiler in @session.pluginManager?.allCompilers or []
    #     new CompilationAction(compiler)
    actions = []
    @ruleSet = @universe.create(RuleSet, { actions, project: this })

    await @watcher.on 'complete', defer()
    debug "Tree scan complete for #{@fullPath}"
    @analyzer.rebuild()
    console.error "Session: %s", @session.constructor.name
    @session.after =>
      @_changed 'fileOptionsByPath'
      @emit 'complete'
    , "#{this}.initialize.complete"

  destroy: ->
    @watcher?.close()
    @stopMonitoring()
    @session._removeProject(this)


  _hostnameForUrl: (url) ->
    try
      components = Url.parse(url)
    catch e
      components = null

    if components?.protocol is 'file:'
      return null
    else
      return components?.hostname or url.split('/')[0]


  'compute snippet': ->
    script = """document.write('<script src="http://' + (location.host || 'localhost').split(':')[0] + ':35729/livereload.js?snipver=2"></' + 'script>')"""

    if @urls.length > 0
      checks =
        for url in @urls when (hostname = @_hostnameForUrl(url))
          "location.hostname === " + JSON.stringify(hostname)
      checks = checks.join(" || ")
      script = "if (#{checks}) { #{script} }"

    return "<script>#{script}</script>"


  'compute availableCompilers': ->
    @session.pluginManager?.allCompilers or []


  'compute compilableFilesFilter': ->
    list = new RelPathList()
    for compiler in @availableCompilers
      for spec in compiler.sourceSpecs
        list.include RelPathSpec.parseGitStyleSpec(spec)
    return list


  setMemento: (@memento) ->
    # log.fyi
    debug "Loading project at #{@path} with memento #{JSON.stringify(@memento, null, 2)}"

    @compilationEnabled   = !!(@memento?.compilationEnabled ? 0)
    @disableLiveRefresh   = !!(@memento?.disableLiveRefresh ? 0)
    @enableRemoteWorkflow = !!(@memento?.enableRemoteServerWorkflow ? 0)
    @fullPageReloadDelay  = Math.floor((@memento?.fullPageReloadDelay ? 0.0) * 1000)
    @eventProcessingDelay = Math.floor((@memento?.eventProcessingDelay ? 0.0) * 1000)
    @rubyVersionId        = @memento?.rubyVersion || 'system'
    @excludedPaths        = @memento?.excludedPaths || []
    @customName           = @memento?.customName || ''
    @nrPathCompsInName    = @memento?.numberOfPathComponentsToUseAsName || 1  # 0 is intentionally turned into 1
    @urls                 = @memento?.urls || []

    @compilerOptionsById = {}
    @fileOptionsByPath = {}

    for own compilerId, compilerOptionsMemento of @memento?.compilers || {}
      if compiler = @session.findCompilerById(compilerId)
        @compilerOptionsById[compilerId] = new CompilerOptions(compiler, compilerOptionsMemento)
        for own filePath, fileOptionsMemento of compilerOptionsMemento.files || {}
          @fileAt(filePath, yes).setMemento fileOptionsMemento

    for fileMemento in @memento?.files or []
      debug "fileMemento: %j", fileMemento
      @fileAt(fileMemento.src, yes).setMemento fileMemento

    debug "@compilerOptionsById = " + JSON.stringify(([i, o.options] for i, o of @compilerOptionsById), null, 2)

    for plugin in @session.plugins
      plugin.loadProject? this, @memento

    @steps = []
    for plugin in @session.plugins
      for step in plugin.createSteps?(this) || []
        step.initialize()
        @steps.push step

    # if @memento.rules?
    #   @ruleSet.setMemento @memento.rules

    # @isLiveReloadBackend = (Path.normalize(@hive.fullPath) == Path.normalize(Path.join(__dirname, '../..')))
    # if @isLiveReloadBackend
    #   log.warn "LiveReload Development Mode enabled. Will restart myself on backend changes."
    #   @hive.requestMonitoring 'ThySelfAutoRestart', yes

  makeMemento: ->
    {
      path: @path
      urls: @urls
      compilationEnabled: !!@compilationEnabled
      disableLiveRefresh: !!@disableLiveRefresh
      files:
        for own _, file of @fileOptionsByPath when file.compiler
          file.makeMemento()
      # rules:
      #   @ruleSet.memento()
    }

  fileAt: (relpath, create=no) ->
    if create
      @fileOptionsByPath[relpath] or= @universe.create(FileOptions, project: this, path: relpath)
    else
      @fileOptionsByPath[relpath]

  _updateFile: (relpath, exists) ->
    file = @fileAt(relpath, exists)
    file?.exists = exists
    file

  startMonitoring: ->
    unless @monitor
      @monitor = @vfs.watch(@path)
      @monitor.on 'change', (path) =>
        @emit 'change', path

  stopMonitoring: ->
    @monitor?.close()
    @monitor = null

  matchesVFS: (vfs) ->
    vfs is @vfs

  matchesPath: (root, path) ->
    @vfs.isSubpath(@fullPath, Path.join(root, path))

  filterPaths: (root, paths) ->
    (path for path in paths when @matchesPath(root, path))

  matchesUrl: (url) ->
    components = Url.parse(url)
    if components.protocol is 'file:'
      return components.pathname.substr(0, @fullPath.length) == @fullPath
    @urls.some (pattern) -> urlmatch(pattern, url)

  handleChange: (vfs, root, paths) ->
    return unless @matchesVFS(vfs)

    paths = @filterPaths(root, paths)
    return if paths.length is 0

    change = { paths, pathsToRefresh: paths }

    run = new Run(this, change, @steps)
    debug "Project.handleChange: created run for %j", paths
    @emit 'run.start', run

    @analyzer.update(paths)

    @session.queue.checkpoint =>
      pathsToProcess = []
      for path in paths
        if (sources = @imports.findSources(path)) and (sources.length > 0) and ((sources.length != 1) or (sources[0] != path))
          debug "Will process #{sources.join(', ')} instead of imported #{path}"
          pathsToProcess.push.apply(pathsToProcess, sources)
        else
          pathsToProcess.push(path)

      change.paths = change.pathsToRefresh = pathsToProcess

      run.once 'finish', =>
        debug "Project.handleChange: finished run for %j", paths
        @emit 'run.finish', run
        @_changed 'fileOptionsByPath'
      run.start()
    , "#{this}.handleChange.after.analyzer.update"

    return run

  reportActionStart: (action) ->
    if !action.id
      throw new Error("Invalid argument: action.id is required")
    @emit 'action.start', action

  reportActionFinish: (action) ->
    if !action.id
      throw new Error("Invalid argument: action.id is required")
    @emit 'action.finish', action

  patchSourceFile: (oldCompiled, newCompiled, callback) ->
    oldLines = oldCompiled.trim().split("\n")
    newLines = newCompiled.trim().split("\n")

    oldLen = oldLines.length
    newLen = newLines.length
    minLen = Math.min(oldLen, newLen)

    prefixLen = 0
    prefixLen++ while (prefixLen < minLen) and (oldLines[prefixLen] == newLines[prefixLen])

    maxSuffixLen = minLen - prefixLen
    suffixLen = 0
    suffixLen++ while (suffixLen < maxSuffixLen) and (oldLines[oldLen - suffixLen - 1] == newLines[newLen - suffixLen - 1])

    if minLen - prefixLen - suffixLen != 1
      debug "Cannot patch source file: minLen = #{minLen}, prefixLen = #{prefixLen}, suffixLen = #{suffixLen}"
      return callback(null)

    oldLine = oldLines[prefixLen]
    newLine = newLines[prefixLen]

    debug "oldLine = %j", oldLine
    debug "newLine = %j", newLine

    SELECTOR_RE = /// ([\w-]+) \s* : (.*?) [;}] ///
    unless (om = oldLine.match SELECTOR_RE) and (nm = newLine.match SELECTOR_RE)
      debug "Cannot match selector regexp"
      return callback(null)

    oldSelector = om[1]; oldValue = om[2].trim()
    newSelector = nm[1]; newValue = nm[2].trim()

    debug "oldSelector = #{oldSelector}, oldValue = '#{oldValue}'"
    debug "newSelector = #{newSelector}, newValue = '#{newValue}'"

    unless oldSelector == newSelector
      debug "Refusing to change oldSelector = #{oldSelector} into newSelector = #{newSelector}"
      return callback(null)

    sourceRef = null
    lineno = prefixLen - 1
    while lineno >= 0
      if m = newLines[lineno].match ///  /\* \s* line \s+ (\d+) \s* [,:] (.*?) \*/ ///
        sourceRef = { path: m[2].trim(), line: parseInt(m[1].trim(), 10) }
        break
      --lineno

    unless sourceRef
      debug "patchSourceFile() cannot find source ref before line #{prefixLen}"
      return callback(null)

    debug "patchSourceFile() foudn source ref %j", sourceRef

    await @vfs.findFilesMatchingSuffixInSubtree @path, sourceRef.path, null, defer(err, srcResult)
    if err
      debug "findFilesMatchingSuffixInSubtree() for src file '#{sourceRef.path}' returned error: #{err.message}"
      return callback(err)

    unless srcResult.bestMatch
      debug "findFilesMatchingSuffixInSubtree() for src file '#{sourceRef.path}' found #{result.bestMatches.length} matches."
      return callback(null)

    fullSrcPath = Path.join(@fullPath, srcResult.bestMatch.path)
    debug "findFilesMatchingSuffixInSubtree() for src file '#{sourceRef.path}' found #{fullSrcPath}"

    await @vfs.readFile fullSrcPath, 'utf8', defer(err, oldSource)
    return callback(err) if err

    REPLACEMENT_RE = /// #{RegExp_escape(oldSelector)} (\s* (?: : \s* )?) #{RegExp_escape(oldValue)} ///

    srcLines = oldSource.split "\n"

    debug "Got #{srcLines.length} lines, looking starting from line #{sourceRef.line - 1}"

    lineno = sourceRef.line - 1
    found = no
    while lineno < srcLines.length
      line = srcLines[lineno ]
      debug "Considering line #{lineno}: #{line}"

      if m = line.match REPLACEMENT_RE
        debug "Matched!"

        line = line.replace REPLACEMENT_RE, (_, sep) -> "#{newSelector}#{sep}#{newValue}"
        srcLines[lineno] = line
        found = yes
        break

      ++lineno

    unless found
      debug "Nothing matched :-("
      return callback null

    newSource = srcLines.join "\n"

    debug "Saving patched source file..."

    await @vfs.writeFile fullSrcPath, newSource, defer(err)
    return callback err if err

    callback null



  saveResourceFromWebInspector: (url, content, callback) ->
    components = Url.parse(url)

    await @vfs.findFilesMatchingSuffixInSubtree @path, components.pathname, null, defer(err, result)
    if err
      debug "findFilesMatchingSuffixInSubtree() returned error: #{err.message}"
      return callback(err)

    if result.bestMatch
      debug "findFilesMatchingSuffixInSubtree() found '#{result.bestMatch.path}'"
      fullPath = Path.join(@fullPath, result.bestMatch.path)

      await @vfs.readFile fullPath, 'utf8', defer(err, oldContent)
      if err
        debug "Loading (pre-save) failed: #{err.message}"
        return callback(err, no)

      debug "Saving #{content.length} characters into #{fullPath}..."
      await @vfs.writeFile fullPath, content, defer(err)
      if err
        debug "Saving failed: #{err.message}"
        return callback(err, no)

      debug "Saving succeeded!"

      if oldContent.match ///  /\* \s* line \s+ \d+ \s* [,:] (.*?) \*/ ///
        await @patchSourceFile oldContent, content, defer(err)
        if err
          debug "patchSourceFile() failed: #{err.message}"
          return callback(err, yes)

      return callback(null, yes)

    else
      debug "findFilesMatchingSuffixInSubtree() found #{result.bestMatches.length} matches."
      return callback(null, no)

module.exports = Project
