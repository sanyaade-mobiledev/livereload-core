Path = require 'path'
R = require 'reactive'


decodeExternalRelativeDir = (dir) ->
  switch dir
    when ''  then null
    when '.' then ''
    else dir

encodeExternalRelativeDir = (dir) ->
  switch dir
    when null then ''
    when ''   then '.'
    else dir


class FileOptions extends R.Model

  schema:
    project:                  { type: Object }
    path:                     { type: String }
    compiler:                 { type: Object }
    memento:                  { type: Object }

    compilable:               { type: Boolean }
    compiled:                 { type: Boolean }
    initialized:              { type: Boolean }
    enabled:                  { type: Boolean }

    outputNameMask:           { type: String }
    outputDir:                { type: String }


  # **/*.coffee -> **/*.js
  # **/*.sass -> **/*.css

  # livereload.json


  # foo/*.css -> foo/foo.min.css

  # bar/xxx.css
  # bar/yyy.css
  # implicit: bar/*.css -> bar.min.css

  # [x] Minify and concatenate

  initialize: (options) ->
    @memento = options.memento or {}

    @enabled = @memento.enabled ? yes

    @setMemento @memento

    Object.defineProperty this, 'outputName', get: => @outputNameForMask(@outputNameMask)

  'get relpath': -> @path

  'get fullPath': -> Path.join(@project.fullPath, @path)

  'get destDir':     -> @outputDir
  'set destDir': (v) -> @outputDir = v

  'get fullDestDir':     -> Path.join(@project.fullPath, @destDir)
  'set fullDestDir': (v) -> @destDir = Path.relative(@project.fullPath, v)

  'get destRelPath': -> Path.join(@outputDir, (@outputNameMask and @outputNameForMask(@outputNameMask) or "<none>"))

  'get isImported': -> @project.imports.hasIncomingEdges(@path)

  setMemento: (@memento) ->
    @exists = @memento.exists ? null

    if @memento.dst
      @outputDir = decodeExternalRelativeDir Path.dirname(@memento.dst)

      @outputNameMask = Path.basename(@memento.dst)
      @outputNameMask = '' if @outputNameMask is '<none>'

    else
      @outputDir = decodeExternalRelativeDir(@memento.output_dir ? '')
      @outputDir or= (if Path.dirname(@path) == '.' then '' else Path.dirname(@path))

      @outputNameMask = @memento.output_file ? ''

  makeMemento: ->
    {
      src: @path
      dst: Path.join(@outputDir, (@outputNameMask or "<none>"))
      exists: (if @exists then undefined else no)
      compiler: @compiler?.id or undefined
    }

  outputNameForMask: (mask) ->
    sourceBaseName = Path.basename(@path, Path.extname(@path))

    # TODO
    # // handle a mask like "*.php" applied to a source file named like "foo.php.jade"
    # while ([destinationNameMask pathExtension].length > 0 && [sourceBaseName pathExtension].length > 0 && [[destinationNameMask pathExtension] isEqualToString:[sourceBaseName pathExtension]]) {
    #     destinationNameMask = [destinationNameMask stringByDeletingPathExtension];
    # }

    mask.replace '*', sourceBaseName


module.exports = FileOptions
