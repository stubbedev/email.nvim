local state = {}
state.page = 1
state.total = 0
state.messages = {}
state.unread = {}
state.reading = false
state.win = {}
state.buf = {}
state.sidebar_rows = {}
state.load_generation = 0
state.polling = false
state.busy = 0
return state
