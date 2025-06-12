# ClodMesh Core Component Examples

# Base Component Class
# All components must extend this class
class ClodMeshComponent extends EventEmitter
  constructor: (@id, @config = {}) ->
    super()
    @state      = 'initialized'
    @health     = status: 'ok', details: {}
    @connections = sends: new Map(), receives: new Map()
    
  # Lifecycle Methods
  initialize: (context) ->
    @context = context
    @logger  = context.logger.child component: @id
    @logger.info 'Initializing component', config: @config
    
    # Validate configuration against schema
    if @constructor.configSchema
      validation = @validateConfig @config
      if not validation.valid
        throw new Error "Invalid configuration: #{validation.errors.join ', '}"
    
    @state = 'ready'
    Promise.resolve()
    
  start: ->
    @logger.info 'Starting component'
    @state = 'running'
    @emit 'started'
    Promise.resolve()
    
  stop: ->
    @logger.info 'Stopping component'
    @state = 'stopped'
    @emit 'stopped'
    Promise.resolve()
    
  # Health Check
  getHealth: ->
    status:  @health.status
    details: @health.details
    state:   @state
    uptime:  process.uptime()
    
  # Message Passing
  send: (target, message) ->
    connection = @connections.sends.get target
    unless connection
      throw new Error "No connection to target: #{target}"
      
    # Add metadata
    envelope =
      jsonrpc: '2.0'
      method:  message.method or 'message'
      params:  message.params or message
      id:      message.id or @generateId()
      meta:
        source:    @id
        target:    target
        timestamp: new Date().toISOString()
        trace_id:  @context.traceId
        
    connection.send envelope
    
  receive: (handler) ->
    listener = (envelope) =>
      try
        result = await handler envelope.params, envelope.meta
        if envelope.id and not envelope.method.endsWith '.notify'
          @reply envelope, result
      catch error
        if envelope.id
          @replyError envelope, error
          
    @on 'message', listener
    
    # Return unsubscribe function
    => @removeListener 'message', listener
    
  # Configuration validation
  validateConfig: (config) ->
    # Simple validation - real implementation would use AJV
    schema = @constructor.configSchema()
    errors = []
    
    # Check required fields
    if schema.required
      for field in schema.required
        unless config[field]?
          errors.push "Missing required field: #{field}"
          
    valid: errors.length is 0
    errors: errors
    
  # Helpers
  generateId: ->
    "#{@id}-#{Date.now()}-#{Math.random().toString(36).substr(2, 9)}"
    
  reply: (originalMessage, result) ->
    @send originalMessage.meta.source,
      jsonrpc: '2.0'
      result:  result
      id:      originalMessage.id
      
  replyError: (originalMessage, error) ->
    @send originalMessage.meta.source,
      jsonrpc: '2.0'
      error:
        code:    error.code or -32603
        message: error.message
        data:    error.data
      id:      originalMessage.id
      
  # Static configuration
  @configSchema: -> {}
  @capabilities: -> []
  @requirements: -> []


# Example: Ollama Connector Component
class OllamaConnector extends ClodMeshComponent
  initialize: (context) ->
    await super context
    
    # Validate Ollama configuration
    @ollamaUrl = @config.url or 'http://localhost:11434'
    @model     = @config.model
    @timeout   = @config.timeout or 30000
    
    unless @model
      throw new Error 'Model configuration required'
      
    # Initialize HTTP client
    @http = require 'axios'
    
    # Test connection
    try
      await @http.get "#{@ollamaUrl}/api/tags"
      @logger.info 'Connected to Ollama', url: @ollamaUrl
    catch error
      throw new Error "Failed to connect to Ollama: #{error.message}"
      
  # Handle incoming requests
  start: ->
    await super()
    
    @receive (message, meta) =>
      switch message.method or message.type
        when 'generate'
          @generate message.prompt, message.options
        when 'chat'
          @chat message.messages, message.options
        else
          throw new Error "Unknown method: #{message.method}"
          
  # Generate completion
  generate: (prompt, options = {}) ->
    @logger.debug 'Generating completion', model: @model
    
    response = await @http.post "#{@ollamaUrl}/api/generate",
      model:       @model
      prompt:      prompt
      temperature: options.temperature or @config.temperature or 0.7
      max_tokens:  options.max_tokens or @config.max_tokens or 2000
      stream:      false
    ,
      timeout: @timeout
      
    response.data.response
    
  # Chat completion
  chat: (messages, options = {}) ->
    @logger.debug 'Chat completion', model: @model, messages: messages.length
    
    # Add system prompt if configured
    if @config.system_prompt and messages[0]?.role isnt 'system'
      messages = [
        role: 'system', content: @config.system_prompt
        ...messages
      ]
      
    response = await @http.post "#{@ollamaUrl}/api/chat",
      model:       @model
      messages:    messages
      temperature: options.temperature or @config.temperature or 0.7
      stream:      false
    ,
      timeout: @timeout
      
    response.data.message
    
  # Health check
  getHealth: ->
    health = await super()
    
    # Check Ollama connection
    try
      await @http.get "#{@ollamaUrl}/api/tags", timeout: 5000
      health.details.ollama = status: 'connected', url: @ollamaUrl
    catch error
      health.status = 'degraded'
      health.details.ollama = status: 'error', error: error.message
      
    health
    
  # Configuration schema
  @configSchema: ->
    type: 'object'
    properties:
      url:
        type:        'string'
        format:      'uri'
        default:     'http://localhost:11434'
        description: 'Ollama API URL'
      model:
        type:        'string'
        description: 'Model identifier'
      system_prompt:
        type:        'string'
        description: 'System prompt to prepend to all chats'
      temperature:
        type:        'number'
        minimum:     0
        maximum:     2
        default:     0.7
        description: 'Sampling temperature'
      max_tokens:
        type:        'integer'
        minimum:     1
        default:     2000
        description: 'Maximum tokens to generate'
      timeout:
        type:        'integer'
        minimum:     1000
        default:     30000
        description: 'Request timeout in milliseconds'
    required: ['model']
    
  @capabilities: -> ['llm', 'chat', 'completion']
  @requirements: -> ['http']


# Example: Message Coordinator Component
class MessageCoordinator extends ClodMeshComponent
  initialize: (context) ->
    await super context
    
    @modes     = @config.modes or ['parallel']
    @defaultMode = @config.default_mode or @modes[0]
    @executors = new Map()
    
    # Load mode executors
    for mode in @modes
      ExecutorClass = require "./executors/#{mode}-executor"
      @executors.set mode, new ExecutorClass(@)
      
    @logger.info 'Loaded executors', modes: @modes
    
  start: ->
    await super()
    
    @receive (message, meta) =>
      mode = message.mode or @defaultMode
      executor = @executors.get mode
      
      unless executor
        throw new Error "Unknown mode: #{mode}"
        
      # Execute the mode
      result = await executor.execute message
      
      # Store in memory if connected
      if @connections.sends.has 'memory'
        @send 'memory',
          method: 'store'
          params:
            type:      'interaction'
            mode:      mode
            input:     message
            output:    result
            metadata:  meta
            
      result
      
  # Route message to targets
  routeToTargets: (targets, message) ->
    promises = []
    
    for target in targets
      if @connections.sends.has target
        promises.push @send target, message
      else
        @logger.warn 'No connection to target', target: target
        
    Promise.all promises
    
  @configSchema: ->
    type: 'object'
    properties:
      modes:
        type:        'array'
        items:       type: 'string', enum: ['parallel', 'sequential', 'debate', 'synthesis', 'handoff']
        default:     ['parallel']
        description: 'Available coordination modes'
      default_mode:
        type:        'string'
        description: 'Default mode if not specified in request'
    required: []
    
  @capabilities: -> ['coordinator', 'router', 'orchestrator']
  @requirements: -> ['message-passing']


# Example: Neo4j Adapter Component  
class Neo4jAdapter extends ClodMeshComponent
  initialize: (context) ->
    await super context
    
    neo4j    = require 'neo4j-driver'
    @driver  = neo4j.driver @config.uri,
      neo4j.auth.basic @config.username, @config.password
      
    # Test connection
    session = @driver.session()
    try
      await session.run 'RETURN 1'
      @logger.info 'Connected to Neo4j', uri: @config.uri
    catch error
      throw new Error "Failed to connect to Neo4j: #{error.message}"
    finally
      await session.close()
      
  start: ->
    await super()
    
    @receive (message, meta) =>
      switch message.method
        when 'store'
          @store message.params
        when 'query'
          @query message.params
        when 'cypher'
          @executeCypher message.params
        else
          throw new Error "Unknown method: #{message.method}"
          
  stop: ->
    await @driver.close()
    await super()
    
  # Store data in graph
  store: ({type, data, metadata}) ->
    session = @driver.session()
    try
      # Create node with automatic timestamp
      result = await session.run """
        CREATE (n:#{type} {
          data: $data,
          metadata: $metadata,
          created_at: datetime(),
          id: randomUUID()
        })
        RETURN n
      """,
        data:     JSON.stringify data
        metadata: JSON.stringify metadata
        
      node = result.records[0].get('n')
      
      id:         node.properties.id
      type:       type
      created_at: node.properties.created_at
    finally
      await session.close()
      
  # Query data
  query: ({type, filter, limit}) ->
    session = @driver.session()
    try
      cypher = """
        MATCH (n:#{type})
        #{if filter then 'WHERE ' + @buildWhereClause(filter) else ''}
        RETURN n
        ORDER BY n.created_at DESC
        LIMIT $limit
      """
      
      result = await session.run cypher, limit: limit or 10
      
      result.records.map (record) ->
        node = record.get('n')
        id:       node.properties.id
        type:     node.labels[0]
        data:     JSON.parse node.properties.data
        metadata: JSON.parse node.properties.metadata
        created:  node.properties.created_at
    finally
      await session.close()
      
  # Execute raw Cypher
  executeCypher: ({query, params}) ->
    unless @config.allow_raw_cypher
      throw new Error 'Raw Cypher queries disabled'
      
    session = @driver.session()
    try
      result = await session.run query, params
      
      records: result.records.map (record) -> record.toObject()
      summary: result.summary
    finally
      await session.close()
      
  # Build WHERE clause from filter object
  buildWhereClause: (filter) ->
    clauses = []
    for key, value of filter
      clauses.push "n.#{key} = '#{value}'"
    clauses.join ' AND '
    
  @configSchema: ->
    type: 'object'
    properties:
      uri:
        type:        'string'
        format:      'uri'
        description: 'Neo4j connection URI'
      username:
        type:        'string'
        description: 'Neo4j username'
      password:
        type:        'string'
        description: 'Neo4j password'
      allow_raw_cypher:
        type:        'boolean'
        default:     false
        description: 'Allow raw Cypher query execution'
    required: ['uri', 'username', 'password']
    
  @capabilities: -> ['storage', 'graph', 'query']
  @requirements: -> ['neo4j-driver']


# Export components
module.exports = {
  ClodMeshComponent
  OllamaConnector
  MessageCoordinator
  Neo4jAdapter
}