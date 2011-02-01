'use strict'

operatorMap =
	'=': 'eq'
	'==': 'eq'
	'>': 'gt'
	'>=': 'ge'
	'<': 'lt'
	'<=': 'le'
	'!=': 'ne'

#
# TODO: consider term be just array -- a[0] === term.name, a[1...] === term.args ?!
#

class Query

	constructor: (query, parameters) ->

		query = '' unless query?

		term = @
		term.name = 'and'
		term.args = []

		topTerm = term

		if typeof query is 'object'
			if _.isArray query
				topTerm.in 'id', query
				return
			else if query instanceof Query
				#_.extend term, query
				#console.log 'term', term
				query = query.toString()
			else
				for k, v of query
					term = new Query()
					topTerm.args.push term
					term.name = 'eq'
					term.args = [k, v]
				return

		query = query.substring(1) if query.charAt(0) is '?'
		if query.indexOf('/') >= 0 # performance guard
			# convert slash delimited text to arrays
			query = query.replace /[\+\*\$\-:\w%\._]*\/[\+\*\$\-:\w%\._\/]*/g, (slashed) ->
				'(' + slashed.replace(/\//g, ',') + ')'

		# convert FIQL to normalized call syntax form
		query = query.replace /(\([\+\*\$\-:\w%\._,]+\)|[\+\*\$\-:\w%\._]*|)([<>!]?=(?:[\w]*=)?|>|<)(\([\+\*\$\-:\w%\._,]+\)|[\+\*\$\-:\w%\._]*|)/g, (t, property, operator, value) ->
			if operator.length < 3
				throw new URIError 'Illegal operator ' + operator unless operatorMap[operator]
				operator = operatorMap[operator]
			else
				operator = operator.substring 1, operator.length - 1
			operator + '(' + property + ',' + value + ')'

		query = query.substring(1) if query.charAt(0) is '?'
		leftoverCharacters = query.replace /(\))|([&\|,])?([\+\*\$\-:\w%\._]*)(\(?)/g, (t, closedParen, delim, propertyOrValue, openParen) ->
			if delim
				if delim is '&'
					op = 'and'
				else if delim is '|'
					op = 'or'
				if op
					if not term.name
						term.name = op
					else if term.name isnt op
						throw new Error 'Can not mix conjunctions within a group, use parenthesis around each set of same conjuctions (& and |)'
			if openParen
				newTerm = new Query()
				newTerm.name = propertyOrValue
				newTerm.parent = term
				term.args.push newTerm
				term = newTerm
			else if closedParen
				isArray = not term.name
				term = term.parent
				throw new URIError 'Closing parenthesis without an opening parenthesis' unless term
				if isArray
					term.args.push term.args.pop().args
			else if propertyOrValue or delim is ','
				term.args.push stringToValue propertyOrValue, parameters
			''
		throw new URIError 'Opening parenthesis without a closing parenthesis' if term.parent
		# any extra characters left over from the replace indicates invalid syntax
		throw new URIError 'Illegal character in query string encountered ' + leftoverCharacters if leftoverCharacters

		removeParentProperty = (obj) ->
			if obj?.args
				delete obj.parent
				_.each obj.args, removeParentProperty
			obj

		removeParentProperty topTerm
		topTerm

	toString: () ->
		if @name is 'and' then _.map(@args, queryToString).join('&') else queryToString @

	where: (query) ->
		@args = @args.concat(new Query(query).args)
		@

	#
	# build mongo structured query
	#
	toMongo: (options) ->

		options ?= {}

		walk = (name, terms) ->
			search = {} # compiled search conditions
			# iterate over terms
			_.each terms or [], (term) ->
				term ?= {}
				func = term.name
				args = term.args
				# ignore bad terms
				# N.B. this filters quirky terms such as for ?or(1,2) -- term here is a plain value
				return unless func and args
				# http://www.mongodb.org/display/DOCS/Querying
				# nested terms? -> recurse
				if typeof args[0]?.name is 'string' and _.isArray args[0].args
					if _.include valid_operators, func
						nested = walk func, args
						search['$'+func] = nested
					# N.B. here we encountered a custom function
					#console.log 'CUSTOM', func, args
					# ...
				# http://www.mongodb.org/display/DOCS/Advanced+Queries
				# structured query syntax
				else
					# handle special functions
					if func is 'sort' or func is 'select' or func is 'values'
						# sort/select/values affect query options
						if func is 'values'
							func = 'select'
							options.toArray = true # flag to invoke _.toArray
						#console.log 'ARGS', args
						pm = plusMinus[func]
						options[func] = {}
						# substitute _id for id
						args = _.map args, (x) -> if x is 'id' or x is '-id' or x is '+id' then '_id' else x
						_.each args, (x, index) ->
							x = x.join('.') if _.isArray x
							a = /([-+]*)(.+)/.exec x
							options[func][a[2]] = pm[(a[1].charAt(0) is '-')*1] * (index+1)
						return
					else if func is 'limit'
						# validate limit() args to be numbers, with sane defaults
						limit = args
						options.skip = +limit[1] or 0
						options.limit = +limit[0] or Infinity
						options.needCount = true
						return
					if func is 'le'
						func = 'lte'
					else if func is 'ge'
						func = 'gte'
					# args[0] is the name of the property
					key = args[0]
					args = args.slice 1
					key = key.join('.') if _.isArray key
					# prohibit keys started with $
					return if String(key).charAt(0) is '$'
					# substitute _id for id
					key = '_id' if key is 'id'
					# the rest args are parameters to func()
					if _.include requires_array, func
						args = args[0]
					# match on regexp means equality
					else if func is 'match'
						func = 'eq'
						regex = new RegExp
						regex.compile.apply regex, args
						args = regex
					else
						# FIXME: do we really need to .join()?!
						args = if args.length is 1 then args[0] else args.join()
					# regexp inequality means negation of equality
					func = 'not' if func is 'ne' and _.isRegExp args
					# valid functions are prepended with $
					if _.include valid_funcs, func
						func = '$'+func
					else
						#console.log 'CUSTOM', func, valid_funcs, args
						# N.B. here we encountered a custom function
						return search
					# $or requires an array of conditions
					#console.log 'COND', search, name, key, func, args
					if name is 'or'
						search = [] unless _.isArray search
						x = {}
						if func is '$eq'
							x[key] = args
						else
							y = {}
							y[func] = args
							x[key] = y
						search.push x
					# other functions pack conditions into object
					else
						# several conditions on the same property are merged into the single object condition
						search[key] = {} if search[key] is undefined
						search[key][func] = args if typeof search[key] is 'object' and not _.isArray search[key]
						# equality flushes all other conditions
						search[key] = args if func is '$eq'
			# TODO: add support for query expressions as Javascript
			# TODO: add support for server-side functions
			#console.log 'OUT', search
			search

		search = walk @name, @args
		#console.log meta: options, search: search, terms: query
		meta: options, search: search

stringToValue = (string, parameters) ->
	converter = converters.default
	if string.charAt(0) is '$'
		param_index = parseInt(string.substring(1), 10) - 1
		return if param_index >= 0 and parameters then parameters[param_index] else undefined
	if string.indexOf(':') >= 0
		parts = string.split ':', 2
		converter = converters[parts[0]]
		throw new URIError 'Unknown converter ' + parts[0] unless converter
		string = parts[1]
	converter string

queryToString = (part) ->
	if _.isArray part
		mapped = _.map part, (arg) -> queryToString arg
		'(' + mapped.join(',') + ')'
	else if part and part.name and part.args
		mapped = _.map part.args, (arg) -> queryToString arg
		part.name + '(' + mapped.join(',') + ')'
	else
		encodeValue part

encodeString = (s) ->
	if typeof s is 'string'
		s = encodeURIComponent s
		s = s.replace('(','%28').replace(')','%29') if s.match /[\(\)]/
	s

encodeValue = (val) ->
	if val is null
		return 'null'
	else if typeof val is 'undefined'
		return val
	if val isnt converters.default('' + (val.toISOString and val.toISOString() or val.toString()))
		type = typeof val
		if _.isRegExp val
			# TODO: control whether to we want simpler glob() style
			val = val.toString()
			i = val.lastIndexOf '/'
			type = if val.substring(i).indexOf('i') >= 0 then 're' else 'RE'
			val = encodeString val.substring(1, i)
			encoded = true
		else if _.isDate val
			type = 'epoch'
			val = val.getTime()
			encoded = true
		else if type is 'string'
			val = encodeString val
			encoded = true
		val = [type, val].join ':'
	val = encodeString val if not encoded and typeof val is 'string'
	val

autoConverted =
	'true': true
	'false': false
	'null': null
	'undefined': undefined
	'Infinity': Infinity
	'-Infinity': -Infinity

converters =
	auto: (string) ->
		if autoConverted.hasOwnProperty string
			return autoConverted[string]
		number = +string
		if _.isNaN(number) or number.toString() isnt string
			string = decodeURIComponent string
			return string
		number
	number: (x) ->
		number = +x
		throw new URIError 'Invalid number ' + x if _.isNaN number
		number
	epoch: (x) ->
		date = new Date +x
		throw new URIError 'Invalid date ' + x unless _.isDate date #if _.isNaN date.getTime()
		date
	isodate: (x) ->
		# four-digit year
		date = '0000'.substr(0, 4-x.length) + x
		# pattern for partial dates
		date += '0000-01-01T00:00:00Z'.substring date.length
		converters.date date
	date: (x) ->
		isoDate = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2}(?:\.\d*)?)Z$/.exec x
		if isoDate
			date = new Date(Date.UTC(+isoDate[1], +isoDate[2] - 1, +isoDate[3], +isoDate[4], +isoDate[5], +isoDate[6]))
		else
			date = new Date x
		throw new URIError 'Invalid date ' + x unless _.isDate date #if _.isNaN date.getTime()
		date
	boolean: (x) ->
		x is 'true'
	string: (string) ->
		decodeURIComponent string
	re: (x) ->
		new RegExp decodeURIComponent(x), 'i'
	RE: (x) ->
		new RegExp decodeURIComponent(x)
	glob: (x) ->
		s = decodeURIComponent(x).replace(/([\\|\||\(|\)|\[|\{|\^|\$|\*|\+|\?|\.|\<|\>])/g, (x) -> '\\'+x
		s = s.replace(/\\\*/g,'.*').replace(/\\\?/g,'.?')
		s = if s.substring(0,2) isnt '.*' then '^'+s else s.substring(2)
		s = if s.substring(s.length-2) isnt '.*' then s+'$' else s.substring(0, s.length-2)
		new RegExp s, 'i'

converters.default = converters.auto

#
#
#
_.each ['eq', 'ne', 'le', 'ge', 'lt', 'gt', 'between', 'in', 'nin', 'contains', 'ncontains', 'or', 'and'], (op) ->
	Query.prototype[op] = (args...) ->
		@args.push
			name: op
			args: args
		@

parse = (query) ->
	try
		q = new Query query
	catch x
		q = new Query
		q.error = x.message
	q

#
# MongoDB
#
# valid funcs
valid_funcs = ['eq', 'ne', 'lt', 'lte', 'gt', 'gte', 'in', 'nin', 'not', 'mod', 'all', 'size', 'exists', 'type', 'elemMatch']
# funcs which definitely require array arguments
requires_array = ['in', 'nin', 'all', 'mod']
# funcs acting as operators
valid_operators = ['or', 'and', 'not'] #, 'xor']
#
plusMinus =
	# [plus, minus]
	sort: [1, -1]
	select: [1, 0]

module.exports =
	#Query: Query
	#parse: parse
	rql: parse

'''

#
# tests
#
inspect = require('./lib/node/eyes.js').inspector stream: null
consoleLog = console.log
console.log = () -> consoleLog inspect arg for arg in arguments


#q1 = new Query 'id!=123&call(p1,p2/p3),sort(-n,+a/b,-id),id>=date:2010'
#q1.where 'u!=false&values(a,-b,c/d,-e/f/g),limit(10)'
#q1.nin('id',[456])
#q1 = new Query('(a=b|c!=re:d|a=d|a!=e)')
#q1 = new Query('a=b&c!=re:d(')
#q2 = new Query()
#console.log q1, ''+q1, q1.toMongo(), ''+q1
q1 = new Query().nin('id',[456])
q2 = new Query(q1)
console.log q1, q2.toMongo()
global.Query = Query
#console.log parse '(123'
require('repl').start 'node>'
'''