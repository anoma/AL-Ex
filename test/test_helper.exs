AL.TestBranch.prepare(AL.Branch.main())
ExUnit.start()
ExUnit.after_suite(fn _result -> AL.TestBranch.cleanup() end)
