R = require 'reactive'

module.exports =
class Invocation extends R.Model

  @PENDING   = PENDING   = 'pending'
  @RUNNING   = RUNNING   = 'running'
  @FINISHED  = FINISHED  = 'finished'
  @CANCELLED = CANCELLED = 'cancelled'

  constructor: (@tool, @info) ->
    @messages  = []
    @status    = PENDING
    @error     = null
    @succeeded = no

  addMessages: (messages) ->
    @messages.push.apply(@messages, messages)
    for message in messages when message.type is 'error'
      if not @error
        @error = message
    emit "messages:changed"

  run: ->
    @status = RUNNING
    @tool.invoke this, =>
      @succeeded = yes unless @error
      @status = FINISHED
      @emit 'finished'
