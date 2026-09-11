examples = AL.Branch.reset_examples()
AL.TestBranch.prepare(examples)
ExUnit.start()
ExUnit.after_suite(fn _result -> AL.TestBranch.cleanup() end)
