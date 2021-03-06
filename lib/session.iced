debug = require('debug')('livereload:core:session')
{ EventEmitter } = require 'events'
Project = require './projects/project'
R = require 'reactive'
{ PluginManager } = require './pluginmgr/plugin'

JobQueue = require 'jobqueue'


class Session extends R.Model

  schema:
    projects:                 { type: Array }


  initialize: (options) ->
    super()

    @plugins = []
    @projectsMemento = {}

    @queue = new JobQueue()

    @CommandLineTool = require('./tools/cmdline')
    @MessageParser = require('./messages/parser')

    for plugin in ['compilation', 'postproc', 'refresh']
      if !options.stdPlugins? or (Array.isArray(options.stdPlugins) and (plugin in options.stdPlugins))
        @addPlugin new (require("./plugins/#{plugin}"))()

    @pluginManager = new PluginManager()

    @rubies = []

    @queue.register { action: 'rescan-plugins' }, @_rescanPlugins.bind(@)
    @queue.add { action: 'rescan-plugins' }

  addPluginFolder: (folder) ->
    @pluginManager.addFolder folder
    @queue.add { action: 'rescan-plugins' }

  addRuby: ({ path, version }) ->
    @rubies.push { path, version }

  setProjectsMemento: (vfs, @projectsMemento) ->
    if (typeof(@projectsMemento) is 'object') and not Array.isArray(@projectsMemento)
      @projectsMemento =
        for own path, projectMemento of @projectsMemento
          projectMemento.path = path
          projectMemento

    @projects = []
    for projectMemento in @projectsMemento
      project = @_addProject @universe.create(Project, session: this, vfs: vfs, path: projectMemento.path)
      project.setMemento projectMemento
    return

  makeProjectsMemento: (callback) ->
    callback null, (project.makeMemento() for project in @projects)

  findProjectById: (projectId) ->
    for project in @projects
      if project.id is projectId
        return project
    null

  findProjectByPath: (path) ->
    for project in @projects
      if project.path is path
        return project
    null

  findProjectByUrl: (url) ->
    for project in @projects
      if project.matchesUrl url
        return project
    null

  findCompilerById: (compilerId) ->
    # return a fake compiler for now to test the memento loading code
    { id: compilerId }

  addProject: (vfs, path) ->
    project = @universe.create(Project, { session: this, vfs, path })
    @_addProject project
    project.setMemento {}

  startMonitoring: ->
    for project in @projects
      project.startMonitoring()

  close: ->
    for project in @projects
      project.stopMonitoring()

  addInterface: (face) ->
    @on 'command', (message) =>
      face.send(message)

    face.on 'command', (connection, message) =>
      @execute message, connection, (err) =>
        console.error err.stack if err

  addPlugin: (plugin) ->
    # sanity check
    unless typeof plugin.metadata is 'object'
      throw new Error "Missing plugin.metadata"
    unless plugin.metadata.apiVersion is 1
      throw new Error "Unsupported API version #{plugin.metadata.apiVersion} requested by plugin #{plugin.metadata.name}"
    @plugins.push plugin

    # for priority in plugin.jobPriorities || []
    #   @queue.addPriority priority

  # call the given func when all previously issued requests have been completed and there's no pending background work
  after: (func, description) ->
    @queue.after =>
      # make sure 'func' is allowed to add more jobs
      process.nextTick func
    , description

  handleChange: (vfs, root, paths) ->
    debug "Session.handleChange root=%j; paths: %j", root, paths
    runs = []
    for project in @projects
      if run = project.handleChange(vfs, root, paths)
        runs.push run
    return runs

  # Hooks up and stores a newly added or loaded project.
  _addProject: (project) ->
    project.on 'change', (path) =>
      @emit 'command', command: 'reload', path: path
    project.on 'action.start', (action) =>
      @emit 'action.start', project, action
    project.on 'action.finish', (action) =>
      @emit 'action.finish', project, action
    project.on 'run.start', (run) =>
      @emit 'run.start', project, run
    project.on 'run.finish', (run) =>
      @emit 'run.finish', project, run
    @projects.push project
    @_changed 'projects'
    project.analyzer.addAnalyzerClass require('./analyzers/compass')
    project.analyzer.addAnalyzerClass require('./analyzers/compilers')
    project.analyzer.addAnalyzerClass require('./analyzers/imports')
    return project

  _removeProject: (project) ->
      if (index = @projects.indexOf(project)) >= 0
        @projects.splice index, 1
        @_changed 'projects'
      undefined

  # message routing
  execute: (message, connection, callback) ->
    if func = @["on #{message.command}"]
      func.call(@, connection, message, callback)
    else
      debug "Ignoring unknown command #{message.command}: #{JSON.stringify(message)}"
      callback(null)

  'on save': (connection, message, callback) ->
    debug "Got save command for URL #{message.url}"
    project = @findProjectByUrl message.url
    if project
      debug "Save: project #{project.path} matches URL #{message.url}"
      project.saveResourceFromWebInspector message.url, message.content, callback
    else
      debug "Save: no match for URL #{message.url}"
      callback(null)

  sendBrowserCommand: (command) ->
    @emit 'browser-command', command

  _rescanPlugins: (request, done) ->
    @pluginManager.rescan(done)


module.exports            = Session
Session.Session           = Session  # for those who prefer to use a destructuring assignment
Session.R                 = require 'reactive'

# private exports for tests
Session.Project           = require './projects/project'
Session.Graph             = require './projects/graph'
Session.MessageFormat     = require './messages/format'
Session.MessageParser     = require './messages/parser'
Session.Action            = require './rules/action'
Session.CompilationAction = require './rules/compilation-action'
Session.RuleSet           = require './rules/ruleset'
Session.CommandLineTool   = require './tools/cmdline'
