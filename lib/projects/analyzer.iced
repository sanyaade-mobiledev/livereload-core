debug  = require('debug')('livereload:core:analyzer')
fs     = require 'fs'
Path   = require 'path'
FSTree = require './tree'

module.exports =
class Analyzer

  constructor: (@project) ->
    @session = @project.session
    @queue   = @session.queue
    @queue.register { project: @project.id, action: 'analyzer-rebuild' }, { idKeys: ['project', 'action'] }, @_rebuild.bind(@)
    @queue.register { project: @project.id, action: 'analyzer-update' }, { idKeys: ['project', 'action'] }, @_update.bind(@)

    @analyzers = []

    @_fullRebuildRequired = yes

  addAnalyzerClass: (analyzerClass) ->
    analyzer = new analyzerClass(@project)
    @analyzers.push analyzer
    @rebuild()  # TODO: rebuild only this analyzer's data


  rebuild: ->
    @queue.add { project: @project.id, action: 'analyzer-rebuild' }

  _rebuild: (request, done) ->
    tree = new FSTree(@project.fullPath)
    await tree.scan defer()

    relpaths = tree.getAllPaths()
    debug "Analyzer found #{relpaths.length} paths: " + relpaths.join(", ")

    for relpath in relpaths
      @project._updateFile(relpath, yes)

    for analyzer in @analyzers
      debug "Running analyzer #{analyzer}"

      analyzer.clear()

      relpaths = tree.findMatchingPaths(analyzer.list)
      debug "#{analyzer} full rebuild will process #{relpaths.length} paths: " + relpaths.join(", ")
      for relpath in relpaths
        if file = @project.fileAt(relpath)
          await setImmediate defer()
          await @_updateFile analyzer, file, defer()

    @_fullRebuildRequired = no
    done()

  update: (relpaths) ->
    return @rebuild() if @_fullRebuildRequired
    @queue.add { project: @project.id, action: 'analyzer-update', relpaths: relpaths.slice(0) }

  _update: (request, done) ->
    debug "Analyzer update job running."

    files = []
    for relpath in request.relpaths
      fullPath = Path.join(@project.fullPath, relpath)
      await fs.exists fullPath, defer(exists)

      debug "file at #{relpath} #{exists && 'exists' || 'does not exist.'}"
      if file = @project._updateFile(relpath, exists)
        files.push file

    for file in files
      for analyzer in @analyzers
        if analyzer.list.matches(file.relpath)
          await setImmediate defer()
          await @_updateFile analyzer, file, defer()
        else
          debug "#{analyzer} not interested in #{file.relpath}"

    for analyzer in @analyzers
      debug "Calling #{analyzer}.after"
      await analyzer.after defer()

    done()

  _updateFile: (analyzer, file, callback) ->
    unless file.exists
      debug "#{analyzer}: deleting info on #{file.relpath}"
      analyzer.removed(file.relpath)
      return callback()

    debug "#{analyzer}: analyzing #{file.relpath}"
    action = { id: 'analyze', message: "Analyzing #{Path.basename(file.relpath)}"}
    @project.reportActionStart(action)
    await analyzer.update file, defer()
    @project.reportActionFinish(action)

    callback()

