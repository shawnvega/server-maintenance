from ansible.plugins.callback import CallbackBase

DOCUMENTATION = '''
    name: retry_load
    type: aggregate
    short_description: Prints system load during until-retry loops
    description:
        - Intercepts retry events and prints the current system load for tasks waiting on system load.
'''

class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'aggregate'
    CALLBACK_NAME = 'retry_load'
    CALLBACK_NEEDS_ENABLED = False

    def v2_runner_retry(self, result):
        task_name = result.task_name or ""
        stdout = result.result.get('stdout', '').strip()
        host = result.host.get_name()
        if stdout and 'load' in task_name.lower():
            self._display.display(
                f"[{host}] Current system load: {stdout} (waiting to drop below threshold)",
                color='bright cyan'
            )
