#include <algorithm>
#include <memory>
#include <utility>

#include "opt-sched/Scheduler/aco.h"
#include "opt-sched/Scheduler/bb_spill.h"
#include "opt-sched/Scheduler/config.h"
#include "opt-sched/Scheduler/graph_trans.h"
#include "opt-sched/Scheduler/list_sched.h"
#include "opt-sched/Scheduler/logger.h"
#include "opt-sched/Scheduler/random.h"
#include "opt-sched/Scheduler/reg_alloc.h"
#include "opt-sched/Scheduler/relaxed_sched.h"
#include "opt-sched/Scheduler/sched_region.h"
#include "opt-sched/Scheduler/stats.h"
#include "opt-sched/Scheduler/utilities.h"
#include "opt-sched/Scheduler/dev_defines.h"

extern bool OPTSCHED_gPrintSpills;

using namespace llvm::opt_sched;

SchedRegion::SchedRegion(MachineModel *machMdl, MachineModel *dev_machMdl, 
		         DataDepGraph *dataDepGraph, long rgnNum, 
			 int16_t sigHashSize, LB_ALG lbAlg,
                         SchedPriorities hurstcPrirts, 
			 SchedPriorities enumPrirts, bool vrfySched,
                         Pruning PruningStrategy, SchedulerType HeurSchedType,
                         SPILL_COST_FUNCTION spillCostFunc) {
  machMdl_ = machMdl;
  dev_machMdl_ = dev_machMdl;
  dataDepGraph_ = dataDepGraph;
  rgnNum_ = rgnNum;
  sigHashSize_ = sigHashSize;
  lbAlg_ = lbAlg;
  hurstcPrirts_ = hurstcPrirts;
  enumPrirts_ = enumPrirts;
  vrfySched_ = vrfySched;
  prune_ = PruningStrategy;
  HeurSchedType_ = HeurSchedType;
  isSecondPass_ = false;

  totalSimSpills_ = INVALID_VALUE;
  bestCost_ = INVALID_VALUE;
  bestSchedLngth_ = INVALID_VALUE;
  hurstcCost_ = INVALID_VALUE;
  enumCrntSched_ = NULL;
  enumBestSched_ = NULL;
  schedLwrBound_ = 0;
  schedUprBound_ = INVALID_VALUE;

  spillCostFunc_ = spillCostFunc;
}

void SchedRegion::UseFileBounds_() {
  InstCount fileLwrBound, fileUprBound;

  dataDepGraph_->UseFileBounds();
  dataDepGraph_->GetFileSchedBounds(fileLwrBound, fileUprBound);
  assert(fileLwrBound >= schedLwrBound_);
  schedLwrBound_ = fileLwrBound;
}

InstSchedule *SchedRegion::AllocNewSched_() {
  InstSchedule *newSched =
      new InstSchedule(machMdl_, dataDepGraph_, vrfySched_);
  return newSched;
}

void SchedRegion::CmputAbslutUprBound_() {
  abslutSchedUprBound_ = dataDepGraph_->GetAbslutSchedUprBound();
}

static bool isBbEnabled(Config &schedIni, Milliseconds rgnTimeout) {
  bool EnableBbOpt = schedIni.GetBool("ENUM_ENABLED");
  if (!EnableBbOpt)
    return false;

  if (rgnTimeout <= 0) {
    Logger::Info("Disabling enumerator becuase region timeout is set to zero.");
    return false;
  }

  return true;
}

__global__
void DevListSched(SchedRegion *dev_rgn, DataDepGraph *dev_DDG, 
		  ListScheduler *dev_lstSchdulr, InstSchedule *dev_lstSched) {

  dev_rgn->SetDepGraph(dev_DDG);
  ((BBWithSpill *)dev_rgn)->SetRegFiles(dev_DDG->getRegFiles());

  FUNC_RESULT rslt = dev_lstSchdulr->FindSchedule(dev_lstSched, dev_rgn);

  if (rslt != RES_SUCCESS) {
      printf("Device List scheduling failed!\n");
  }

  // Compute schedule costs
  InstCount hurstcExecCost;
  ((BBWithSpill *)(dev_rgn))->Dev_CmputNormCost_(dev_lstSched, CCM_DYNMC, hurstcExecCost, true);
}

__global__
void Reset(DataDepGraph **dev_maxDDG) {
  (*dev_maxDDG)->Reset();
}

FUNC_RESULT SchedRegion::FindOptimalSchedule(
    Milliseconds rgnTimeout, Milliseconds lngthTimeout, bool &isLstOptml,
    InstCount &bestCost, InstCount &bestSchedLngth, InstCount &hurstcCost,
    InstCount &hurstcSchedLngth, InstSchedule *&bestSched, bool filterByPerp,
    const BLOCKS_TO_KEEP blocksToKeep) {
  ListScheduler *lstSchdulr = NULL;
  InstSchedule *InitialSchedule = nullptr;
  InstSchedule *lstSched = NULL;
  InstSchedule *AcoSchedule = nullptr;
  InstCount InitialScheduleLength = 0;
  InstCount InitialScheduleCost = 0;
  FUNC_RESULT rslt = RES_SUCCESS;
  Milliseconds hurstcTime = 0;
  Milliseconds boundTime = 0;
  Milliseconds enumTime = 0;
  Milliseconds vrfyTime = 0;
  Milliseconds AcoTime = 0;
  Milliseconds AcoStart = 0;
  InstCount heuristicScheduleLength = INVALID_VALUE;
  InstCount AcoScheduleLength_ = INVALID_VALUE;
  InstCount AcoScheduleCost_ = INVALID_VALUE;

  enumCrntSched_ = NULL;
  enumBestSched_ = NULL;
  bestSched = bestSched_ = NULL;

  bool AcoBeforeEnum = false;
  bool AcoAfterEnum = false;

  // Do we need to compute the graph's transitive closure?
  bool needTransitiveClosure = false;

  // Algorithm run order:
  // 1) Heuristic Scheduler
  // 2) ACO
  // 3) Branch & Bound Enumerator
  // 4) ACO
  // Each of these 4 algorithms can be individually disabled, but either the
  // heuristic scheduler or ACO before the branch & bound enumerator must be
  // enabled.
  Config &schedIni = SchedulerOptions::getInstance();
  bool HeuristicSchedulerEnabled = schedIni.GetBool("HEUR_ENABLED");
  bool AcoSchedulerEnabled = schedIni.GetBool("ACO_ENABLED");
  bool BbSchedulerEnabled = isBbEnabled(schedIni, rgnTimeout);

  if (AcoSchedulerEnabled) {
    AcoBeforeEnum = schedIni.GetBool("ACO_BEFORE_ENUM");
    AcoAfterEnum = schedIni.GetBool("ACO_AFTER_ENUM");
  }

  if (!HeuristicSchedulerEnabled && !AcoBeforeEnum) {
    // Abort if ACO and heuristic algorithms are disabled.
    Logger::Fatal(
        "Heuristic list scheduler or ACO must be enabled before enumerator.");
    return RES_ERROR;
  }

  Logger::Info("---------------------------------------------------------------"
               "------------");
  Logger::Info("Processing DAG %s with %d insts and max latency %d.",
               dataDepGraph_->GetDagID(), dataDepGraph_->GetInstCnt(),
               dataDepGraph_->GetMaxLtncy());

  stats::problemSize.Record(dataDepGraph_->GetInstCnt());

  const auto *GraphTransformations = dataDepGraph_->GetGraphTrans();
  if (BbSchedulerEnabled || GraphTransformations->size() > 0 ||
      spillCostFunc_ == SCF_SLIL)
    needTransitiveClosure = true;

  rslt = dataDepGraph_->SetupForSchdulng(needTransitiveClosure);
  if (rslt != RES_SUCCESS) {
    Logger::Info("Invalid input DAG");
    return rslt;
  }

  // Apply graph transformations
  for (auto &GT : *GraphTransformations) {
    rslt = GT->ApplyTrans();

    if (rslt != RES_SUCCESS)
      return rslt;

    // Update graph after each transformation
    rslt = dataDepGraph_->UpdateSetupForSchdulng(needTransitiveClosure);
    if (rslt != RES_SUCCESS) {
      Logger::Info("Invalid DAG after graph transformations");
      return rslt;
    }
  }

  SetupForSchdulng_();
  CmputAbslutUprBound_();
  schedLwrBound_ = dataDepGraph_->GetSchedLwrBound();

  // We can calculate lower bounds here since it is only dependent
  // on schedLwrBound_
  if (!BbSchedulerEnabled)
    costLwrBound_ = CmputCostLwrBound();
  else
    CmputLwrBounds_(false);

  // Log the lower bound on the cost, allowing tools reading the log to compare
  // absolute rather than relative costs.
  Logger::Info("Lower bound of cost before scheduling: %d", costLwrBound_);

  // Step #1: Find the heuristic schedule if enabled.
  // Note: Heuristic scheduler is required for the two-pass scheduler
  // to use the sequential list scheduler which inserts stalls into
  // the schedule found in the first pass.
  if (HeuristicSchedulerEnabled || IsSecondPass()) { 
    InstCount hurstcExecCost;
    //****Begin Code for ListScheduling on Device****
    Milliseconds hurstcStart = Utilities::GetProcessorTime();
    //if true run DevListSched
    if (false) {
/*
      size_t memSize;
      // Copy DDG to device
      Logger::Info("Copying DDG to device");
      DataDepGraph *dev_DDG;
      memSize = sizeof(DataDepGraph);
      gpuErrchk(cudaMallocManaged(&dev_DDG, memSize));
      gpuErrchk(cudaMemcpy(dev_DDG, dataDepGraph_, memSize, 
			   cudaMemcpyHostToDevice));
      dataDepGraph_->CopyPointersToDevice(dev_DDG);
      // Copy this(BBWithSpill) to device
      BBWithSpill *dev_rgn = NULL;
      // Allocate device mem
      memSize = sizeof(BBWithSpill);
      gpuErrchk(cudaMallocManaged((void**)&dev_rgn, memSize));
      // Copy this to device
      gpuErrchk(cudaMemcpy(dev_rgn, this, memSize, cudaMemcpyHostToDevice));
      // Update dev_rgn->machMdl_ to dev_machMdl
      gpuErrchk(cudaMemcpy(&(dev_rgn->machMdl_), &dev_machMdl_,
			   sizeof(MachineModel *),cudaMemcpyHostToDevice));
      CopyPointersToDevice(dev_rgn, 1);
      // Create and copy lstSched
      lstSched = new InstSchedule(machMdl_, dataDepGraph_, vrfySched_);
      InstSchedule *dev_lstSched = NULL;
      // Move lstSched arrays to device
      lstSched->CopyPointersToDevice(dev_machMdl_);
      // Allocate dev mem for dev_lstSched
      memSize = sizeof(InstSchedule);
      gpuErrchk(cudaMalloc((void**)&dev_lstSched, memSize));
      // Copy lstSched to device
      gpuErrchk(cudaMemcpy(dev_lstSched, lstSched, memSize,
	  	cudaMemcpyHostToDevice));
      // Create and copy list scheduler to device
      ListScheduler *lstSchdulr, *dev_lstSchdulr;
      lstSchdulr = new ListScheduler(dataDepGraph_, machMdl_, 
		                     abslutSchedUprBound_, 
				     GetHeuristicPriorities());
      memSize = sizeof(ListScheduler);
      gpuErrchk(cudaMallocManaged(&dev_lstSchdulr, memSize));
      gpuErrchk(cudaMemcpy(dev_lstSchdulr, lstSchdulr, memSize,
			   cudaMemcpyHostToDevice));
      lstSchdulr->CopyPointersToDevice(dev_lstSchdulr, dev_DDG, dev_machMdl_);
      delete lstSchdulr;
      // Launch device list sched kernel
      Logger::Info("Launching device list scheduling kernel");
      DevListSched<<<1,1>>>(dev_rgn, dev_DDG, dev_lstSchdulr, dev_lstSched);
      cudaDeviceSynchronize(); 
      Logger::Info("Post Kernel Error: %s", cudaGetErrorString(cudaGetLastError()));
      // Copy ListSchedule to Host
      memSize = sizeof(InstSchedule);
      gpuErrchk(cudaMemcpy(lstSched, dev_lstSched, memSize,
			   cudaMemcpyDeviceToHost)); 
      lstSched->CopyPointersToHost(machMdl_);
      //dev_DDG->FreeDevicePointers();
      cudaFree(dev_DDG);
      dev_lstSchdulr->FreeDevicePointers();
      cudaFree(dev_lstSchdulr);
      dev_rgn->FreeDevicePointers(1);
      cudaFree(dev_rgn);
      heuristicScheduleLength = lstSched->GetCrntLngth();
      hurstcExecCost = lstSched->GetExecCost();  
      hurstcCost_ = lstSched->GetCost();
      ****End Device Code****
*/
    }

    hurstcTime = Utilities::GetProcessorTime() - hurstcStart;
    stats::heuristicTime.Record(hurstcTime);
    if (hurstcTime > 0)
      Logger::Info("Heuristic_Time %d", hurstcTime);

    // If true, run list scheduling on the host
    if (true) {
      //Logger::Info("Running host list scheduling to check for correctness");

      InstSchedule *host_lstSched = new InstSchedule(machMdl_, dataDepGraph_, vrfySched_);

      //lstSchdulr = AllocHeuristicScheduler_();
      lstSchdulr = new ListScheduler(dataDepGraph_, machMdl_, 
                                     abslutSchedUprBound_, 
                                     GetHeuristicPriorities());

      rslt = lstSchdulr->FindSchedule(host_lstSched, this);

      if (rslt != RES_SUCCESS) {
        Logger::Fatal("List scheduling failed");
        delete lstSchdulr;
        delete lstSched;
        return rslt;
      }

      // Compute cost for Heuristic list scheduler, this must be called before
      // calling GetCost() on the InstSchedule instance.
      InstCount hurstcExecCost;
      CmputNormCost_(host_lstSched, CCM_DYNMC, hurstcExecCost, true);
      
      // if true compare dev and lstsched, if false set hostlstsched as lstsched
      if (false) {
/*
        bool match = true;
    
        for (InstCount i = 0; i < dataDepGraph_->GetInstCnt(); i++) {
          if (host_lstSched->GetSchedCycle(i) != lstSched->GetSchedCycle(i))
            match = false;
        }

        if (lstSched->GetCost() != host_lstSched->GetCost()) {
          Logger::Info("Host Schedule Cost: %d", host_lstSched->GetCost());
	  Logger::Info("Device Schedule Cost: %d", lstSched->GetCost());
          Logger::Info("**** Host and Device Schedules have different costs ****");
        }

        if (match) {
          Logger::Info("Host and device schedules match!");
	} else {
          Logger::Info("Host Schedule:");
          host_lstSched->Print();
          Logger::Info("Device Schedule");
          lstSched->Print();
          Logger::Info("******** Host and Device Schedule mismatch ********");
	}
*/
      } else {
        lstSched = host_lstSched;
        heuristicScheduleLength = lstSched->GetCrntLngth();
        hurstcCost_ = lstSched->GetCost();
      }
    }

    // This schedule is optimal so ACO will not be run
    // so set bestSched here.
    if (hurstcCost_ == 0) {
      isLstOptml = true;
      bestSched = bestSched_ = lstSched;
      bestSchedLngth_ = heuristicScheduleLength;
      bestCost_ = hurstcCost_;
    }

    FinishHurstc_();

    //  #ifdef IS_DEBUG_SOLN_DETAILS_1
    Logger::Info(
        "The list schedule is of length %d and spill cost %d. Tot cost = %d",
        heuristicScheduleLength, lstSched->GetSpillCost(), hurstcCost_);
    //  #endif

#ifdef IS_DEBUG_PRINT_SCHEDS
    lstSched->Print(Logger::GetLogStream(), "Heuristic");
#endif
#ifdef IS_DEBUG_PRINT_BOUNDS
    dataDepGraph_->PrintLwrBounds(DIR_FRWRD, Logger::GetLogStream(),
                                  "CP Lower Bounds");
#endif
  }

  // Step #2: Use ACO to find a schedule if enabled and no optimal schedule is
  // yet to be found.
  if (AcoBeforeEnum && dataDepGraph_->GetInstCnt() < 20)
    AcoBeforeEnum = false;
  if (AcoBeforeEnum && !isLstOptml) {
    AcoStart = Utilities::GetProcessorTime();
    AcoSchedule = new InstSchedule(machMdl_, dataDepGraph_, vrfySched_);

    rslt = runACO(AcoSchedule, lstSched);
    if (rslt != RES_SUCCESS) {
      Logger::Fatal("ACO scheduling failed");
      if (lstSchdulr)
        delete lstSchdulr;
      if (lstSched)
        delete lstSched;
      delete AcoSchedule;
      return rslt;
    }

    AcoTime = Utilities::GetProcessorTime() - AcoStart;
    stats::AcoTime.Record(AcoTime);
    if (AcoTime > 0)
      Logger::Info("ACO_Time %d", AcoTime);

    AcoScheduleLength_ = AcoSchedule->GetCrntLngth();
    AcoScheduleCost_ = AcoSchedule->GetCost();

    // If ACO is run then that means either:
    // 1.) Heuristic was not run
    // 2.) Heuristic was not optimal
    // In both cases, the current best will be ACO if
    // ACO is optimal so set bestSched here.
    if (AcoScheduleCost_ == 0) {
      isLstOptml = true;
      bestSched = bestSched_ = AcoSchedule;
      bestSchedLngth_ = AcoScheduleLength_;
      bestCost_ = AcoScheduleCost_;
    }
  }

  // If an optimal schedule was found then it should have already
  // been taken care of when optimality was discovered.
  // Thus we only account for cases where no optimal schedule
  // was found.
  if (!isLstOptml) {
    // There are 3 possible situations:
    // A) ACO was never run. In that case, just use Heuristic and run with its
    // results, into B&B.
    if (!AcoBeforeEnum) {
      bestSched = bestSched_ = lstSched;
      bestSchedLngth_ = heuristicScheduleLength;
      bestCost_ = hurstcCost_;
    }
    // B) Heuristic was never run. In that case, just use ACO and run with its
    // results, into B&B.
    else if (!HeuristicSchedulerEnabled) {
      bestSched = bestSched_ = AcoSchedule;
      bestSchedLngth_ = AcoScheduleLength_;
      bestCost_ = AcoScheduleCost_;
      // C) Neither scheduler was optimal. In that case, compare the two
      // schedules and use the one that's better as the input (initialSched) for
      // B&B.
    } else {
      bestSched_ = AcoScheduleCost_ < hurstcCost_ ? AcoSchedule : lstSched;
      bestSched = bestSched_;
      bestSchedLngth_ = bestSched_->GetCrntLngth();
      bestCost_ = bestSched_->GetCost();
    }
  }
  // Step #3: Compute the cost upper bound.
  Milliseconds boundStart = Utilities::GetProcessorTime();
  assert(bestSchedLngth_ >= schedLwrBound_);
  assert(schedLwrBound_ <= bestSched_->GetCrntLngth());

  // Calculate upper bounds with the best schedule found
  CmputUprBounds_(bestSched_, false);
  boundTime = Utilities::GetProcessorTime() - boundStart;
  stats::boundComputationTime.Record(boundTime);

#ifdef IS_DEBUG_PRINT_SCHEDS
  lstSched->Print(Logger::GetLogStream(), "Heuristic");
#endif
#ifdef IS_DEBUG_PRINT_BOUNDS
  dataDepGraph_->PrintLwrBounds(DIR_FRWRD, Logger::GetLogStream(),
                                "CP Lower Bounds");
#endif

  // (Chris): If the cost function is SLIL, then the list schedule is considered
  // optimal if PERP is 0.
  if (filterByPerp && !isLstOptml && spillCostFunc_ == SCF_SLIL) {
    const InstCount *regPressures = nullptr;
    auto regTypeCount = lstSched->GetPeakRegPressures(regPressures);
    InstCount sumPerp = 0;
    for (int i = 0; i < regTypeCount; ++i) {
      int perp = regPressures[i] - machMdl_->GetPhysRegCnt(i);
      if (perp > 0)
        sumPerp += perp;
    }
    if (sumPerp == 0) {
      isLstOptml = true;
      Logger::Info("Marking SLIL list schedule as optimal due to zero PERP.");
    }
  }

#if defined(IS_DEBUG_SLIL_OPTIMALITY)
  // (Chris): This code prints a statement when a schedule is SLIL-optimal but
  // not PERP-optimal.
  if (spillCostFunc_ == SCF_SLIL && bestCost_ == 0) {
    const InstCount *regPressures = nullptr;
    auto regTypeCount = lstSched->GetPeakRegPressures(regPressures);
    InstCount sumPerp = 0;
    for (int i = 0; i < regTypeCount; ++i) {
      int perp = regPressures[i] - machMdl_->GetPhysRegCnt(i);
      if (perp > 0)
        sumPerp += perp;
    }
    if (sumPerp > 0) {
      Logger::Info("Dag %s is SLIL optimal but not PERP optimal (PERP=%d).",
                   dataDepGraph_->GetDagID(), sumPerp);
    }
  }
#endif
  if (EnableEnum_() == false) {
    delete lstSchdulr;
    return RES_FAIL;
  }

#ifdef IS_DEBUG_BOUNDS
  Logger::Info("Sched LB = %d, Sched UB = %d", schedLwrBound_, schedUprBound_);
#endif

  InitialSchedule = bestSched_;
  InitialScheduleCost = bestCost_;
  InitialScheduleLength = bestSchedLngth_;

  // Step #4: Find the optimal schedule if the heuristc and ACO was not optimal.
  if (BbSchedulerEnabled) {
    Milliseconds enumStart = Utilities::GetProcessorTime();
    if (!isLstOptml) {
      dataDepGraph_->SetHard(true);
      rslt = Optimize_(enumStart, rgnTimeout, lngthTimeout);
      Milliseconds enumTime = Utilities::GetProcessorTime() - enumStart;

      // TODO: Implement this stat for ACO also.
      if (hurstcTime > 0) {
        enumTime /= hurstcTime;
        stats::enumerationToHeuristicTimeRatio.Record(enumTime);
      }

      if (bestCost_ < InitialScheduleCost) {
        assert(enumBestSched_ != NULL);
        bestSched = bestSched_ = enumBestSched_;
#ifdef IS_DEBUG_PRINT_SCHEDS
        enumBestSched_->Print(Logger::GetLogStream(), "Optimal");
#endif
      }
    } else if (rgnTimeout == 0) {
      Logger::Info(
          "Bypassing optimal scheduling due to zero time limit with cost %d",
          bestCost_);
    } else {
      Logger::Info("The initial schedule of length %d and cost %d is optimal.",
                   bestSchedLngth_, bestCost_);
    }

    if (rgnTimeout != 0) {
      bool optimalSchedule = isLstOptml || (rslt == RES_SUCCESS);
      Logger::Info("Best schedule for DAG %s has cost %d and length %d. The "
                   "schedule is %s",
                   dataDepGraph_->GetDagID(), bestCost_, bestSchedLngth_,
                   optimalSchedule ? "optimal" : "not optimal");
    }

#ifdef IS_DEBUG_PRINT_PERP_AT_EACH_STEP
    Logger::Info("Printing PERP at each step in the schedule.");

    int costSum = 0;
    for (int i = 0; i < dataDepGraph_->GetInstCnt(); ++i) {
      Logger::Info("Cycle: %lu Cost: %lu", i, bestSched_->GetSpillCost(i));
      costSum += bestSched_->GetSpillCost(i);
    }
    Logger::Info("Cost Sum: %lu", costSum);
#endif

    if (SchedulerOptions::getInstance().GetString(
            "SIMULATE_REGISTER_ALLOCATION") != "NO") {
      //#ifdef IS_DEBUG
      RegAlloc_(bestSched, InitialSchedule);
      //#endif
    }

    enumTime = Utilities::GetProcessorTime() - enumStart;
    stats::enumerationTime.Record(enumTime);
  }

  // Step 5: Run ACO if schedule from enumerator is not optimal
  if (bestCost_ != 0 && AcoAfterEnum) {
    Logger::Info("Final cost is not optimal, running ACO.");
    InstSchedule *AcoAfterEnumSchedule =
        new InstSchedule(machMdl_, dataDepGraph_, vrfySched_);

    FUNC_RESULT acoRslt = runACO(AcoAfterEnumSchedule, bestSched);
    if (acoRslt != RES_SUCCESS) {
      Logger::Info("Running final ACO failed");
      delete AcoAfterEnumSchedule;
    } else {
      InstCount AcoAfterEnumCost = AcoAfterEnumSchedule->GetCost();
      if (AcoAfterEnumCost < bestCost_) {
        InstCount AcoAfterEnumLength = AcoAfterEnumSchedule->GetCrntLngth();
        InstCount imprvmnt = bestCost_ - AcoAfterEnumCost;
        Logger::Info(
            "ACO found better schedule with length=%d, spill cost = %d, "
            "tot cost = %d, cost imp=%d.",
            AcoAfterEnumLength, AcoAfterEnumSchedule->GetSpillCost(),
            AcoAfterEnumCost, imprvmnt);
        bestSched_ = bestSched = AcoAfterEnumSchedule;
        bestCost_ = AcoAfterEnumCost;
        bestSchedLngth_ = AcoAfterEnumLength;
      } else {
        Logger::Info("ACO was unable to find a better schedule.");
        delete AcoAfterEnumSchedule;
      }
    }
  }

  Milliseconds vrfyStart = Utilities::GetProcessorTime();
  if (vrfySched_) {
    bool isValidSchdul = bestSched->Verify(machMdl_, dataDepGraph_);

    if (isValidSchdul == false) {
      stats::invalidSchedules++;
    }
  }

  vrfyTime = Utilities::GetProcessorTime() - vrfyStart;
  stats::verificationTime.Record(vrfyTime);

  InstCount finalLwrBound = costLwrBound_;
  InstCount finalUprBound = costLwrBound_ + bestCost_;
  if (rslt == RES_SUCCESS)
    finalLwrBound = finalUprBound;

  dataDepGraph_->SetFinalBounds(finalLwrBound, finalUprBound);

  FinishOptml_();

  bool tookBest = ChkSchedule_(bestSched, InitialSchedule);
  if (tookBest == false) {
    bestCost_ = InitialScheduleCost;
    bestSchedLngth_ = InitialScheduleLength;
  }

  if (lstSchdulr) {
    delete lstSchdulr;
  }
  if (NULL != lstSched && bestSched != lstSched) {
    delete lstSched;
  }
  if (NULL != AcoSchedule && bestSched != AcoSchedule) {
    delete AcoSchedule;
  }
  if (enumBestSched_ != NULL && bestSched != enumBestSched_)
    delete enumBestSched_;
  if (enumCrntSched_ != NULL)
    delete enumCrntSched_;

  bestCost = bestCost_;
  bestSchedLngth = bestSchedLngth_;
  hurstcCost = hurstcCost_;
  hurstcSchedLngth = heuristicScheduleLength;

  // (Chris): Experimental. Discard the schedule based on sched.ini setting.
  if (spillCostFunc_ == SCF_SLIL) {
    bool optimal = isLstOptml || (rslt == RES_SUCCESS);
    if ((blocksToKeep == BLOCKS_TO_KEEP::ZERO_COST && bestCost != 0) ||
        (blocksToKeep == BLOCKS_TO_KEEP::OPTIMAL && !optimal) ||
        (blocksToKeep == BLOCKS_TO_KEEP::IMPROVED &&
         !(bestCost < InitialScheduleCost)) ||
        (blocksToKeep == BLOCKS_TO_KEEP::IMPROVED_OR_OPTIMAL &&
         !(optimal || bestCost < InitialScheduleCost))) {
      delete bestSched;
      bestSched = nullptr;
      return rslt;
    }
  }

  // TODO: Update this to account for using heuristic scheduler and ACO.
#if defined(IS_DEBUG_COMPARE_SLIL_BB)
  {
    const auto &status = [&]() {
      switch (rslt) {
      case RES_SUCCESS:
        return "optimal";
      case RES_TIMEOUT:
        return "timeout";
      default:
        return "failed";
      }
    }();
    if (!isLstOptml) {
      Logger::Info("Dag %s %s cost %d time %lld", dataDepGraph_->GetDagID(),
                   status, bestCost_, enumTime);
      Logger::Info("Dag %s %s absolute cost %d time %lld",
                   dataDepGraph_->GetDagID(), status, bestCost_ + costLwrBound_,
                   enumTime);
    }
  }
  {
    if (spillCostFunc_ == SCF_SLIL && rgnTimeout != 0) {
      // costLwrBound_: static lower bound
      // bestCost_: total cost of the best schedule relative to static lower
      // bound

      auto isEnumerated = [&]() { return (!isLstOptml) ? "True" : "False"; }();

      auto isOptimal = [&]() {
        return (isLstOptml || (rslt == RES_SUCCESS)) ? "True" : "False";
      }();

      auto isPerpHigherThanHeuristic = [&]() {
        auto getSumPerp = [&](InstSchedule *sched) {
          const InstCount *regPressures = nullptr;
          auto regTypeCount = sched->GetPeakRegPressures(regPressures);
          InstCount sumPerp = 0;
          for (int i = 0; i < regTypeCount; ++i) {
            int perp = regPressures[i] - machMdl_->GetPhysRegCnt(i);
            if (perp > 0)
              sumPerp += perp;
          }
          return sumPerp;
        };

        if (lstSched == bestSched)
          return "False";

        auto heuristicPerp = getSumPerp(lstSched);
        auto bestPerp = getSumPerp(bestSched);

        return (bestPerp > heuristicPerp) ? "True" : "False";
      }();

      Logger::Info("SLIL stats: DAG %s static LB %d gap size %d enumerated %s "
                   "optimal %s PERP higher %s",
                   dataDepGraph_->GetDagID(), costLwrBound_, bestCost_,
                   isEnumerated, isOptimal, isPerpHigherThanHeuristic);
    }
  }
#endif
#if defined(IS_DEBUG_FINAL_SPILL_COST)
  // (Chris): Unconditionally Print out the spill cost of the final schedule.
  // This makes it easy to compare results.
  Logger::Info("Final spill cost is %d for DAG %s.", bestSched_->GetSpillCost(),
               dataDepGraph_->GetDagID());
#endif
#if defined(IS_DEBUG_PRINT_PEAK_FOR_ENUMERATED)
  if (!isLstOptml) {
    InstCount maxSpillCost = 0;
    for (int i = 0; i < dataDepGraph_->GetInstCnt(); ++i) {
      if (bestSched->GetSpillCost(i) > maxSpillCost)
        maxSpillCost = bestSched->GetSpillCost(i);
    }
    Logger::Info("DAG %s PEAK %d", dataDepGraph_->GetDagID(), maxSpillCost);
  }
#endif
  return rslt;
}

FUNC_RESULT SchedRegion::Optimize_(Milliseconds startTime,
                                   Milliseconds rgnTimeout,
                                   Milliseconds lngthTimeout) {
  Enumerator *enumrtr;
  FUNC_RESULT rslt = RES_SUCCESS;

  enumCrntSched_ = AllocNewSched_();
  enumBestSched_ = AllocNewSched_();

  InstCount initCost = bestCost_;
  enumrtr = AllocEnumrtr_(lngthTimeout);
  rslt = Enumerate_(startTime, rgnTimeout, lngthTimeout);

  Milliseconds solnTime = Utilities::GetProcessorTime() - startTime;

#ifdef IS_DEBUG_NODES
  Logger::Info("Examined %lld nodes.", enumrtr->GetNodeCnt());
#endif
  stats::nodeCount.Record(enumrtr->GetNodeCnt());
  stats::solutionTime.Record(solnTime);

  InstCount imprvmnt = initCost - bestCost_;
  if (rslt == RES_SUCCESS) {
    Logger::Info("DAG solved optimally in %lld ms with "
                 "length=%d, spill cost = %d, tot cost = %d, cost imp=%d.",
                 solnTime, bestSchedLngth_, bestSched_->GetSpillCost(),
                 bestCost_, imprvmnt);
    stats::solvedProblemSize.Record(dataDepGraph_->GetInstCnt());
    stats::solutionTimeForSolvedProblems.Record(solnTime);
  } else {
    if (rslt == RES_TIMEOUT) {
      Logger::Info("DAG timed out with "
                   "length=%d, spill cost = %d, tot cost = %d, cost imp=%d.",
                   bestSchedLngth_, bestSched_->GetSpillCost(), bestCost_,
                   imprvmnt);
    }
    stats::unsolvedProblemSize.Record(dataDepGraph_->GetInstCnt());
  }

  return rslt;
}

void SchedRegion::CmputLwrBounds_(bool useFileBounds) {
  RelaxedScheduler *rlxdSchdulr = NULL;
  RelaxedScheduler *rvrsRlxdSchdulr = NULL;
  InstCount rlxdUprBound = dataDepGraph_->GetAbslutSchedUprBound();

  switch (lbAlg_) {
  case LBA_LC:
    rlxdSchdulr = new LC_RelaxedScheduler(dataDepGraph_, machMdl_, rlxdUprBound,
                                          DIR_FRWRD);
    rvrsRlxdSchdulr = new LC_RelaxedScheduler(dataDepGraph_, machMdl_,
                                              rlxdUprBound, DIR_BKWRD);
    break;
  case LBA_RJ:
    rlxdSchdulr = new RJ_RelaxedScheduler(dataDepGraph_, machMdl_, rlxdUprBound,
                                          DIR_FRWRD, RST_STTC);
    rvrsRlxdSchdulr = new RJ_RelaxedScheduler(
        dataDepGraph_, machMdl_, rlxdUprBound, DIR_BKWRD, RST_STTC);
    break;
  }

  InstCount frwrdLwrBound = 0;
  InstCount bkwrdLwrBound = 0;
  frwrdLwrBound = rlxdSchdulr->FindSchedule();
  bkwrdLwrBound = rvrsRlxdSchdulr->FindSchedule();
  InstCount rlxdLwrBound = std::max(frwrdLwrBound, bkwrdLwrBound);

  assert(rlxdLwrBound >= schedLwrBound_);

  if (rlxdLwrBound > schedLwrBound_)
    schedLwrBound_ = rlxdLwrBound;

#ifdef IS_DEBUG_PRINT_BOUNDS
  dataDepGraph_->PrintLwrBounds(DIR_FRWRD, Logger::GetLogStream(),
                                "Relaxed Forward Lower Bounds");
  dataDepGraph_->PrintLwrBounds(DIR_BKWRD, Logger::GetLogStream(),
                                "Relaxed Backward Lower Bounds");
#endif

  if (useFileBounds)
    UseFileBounds_();

  costLwrBound_ = CmputCostLwrBound();

  delete rlxdSchdulr;
  delete rvrsRlxdSchdulr;
}

bool SchedRegion::CmputUprBounds_(InstSchedule *schedule, bool useFileBounds) {
  if (useFileBounds) {
    hurstcCost_ = dataDepGraph_->GetFileCostUprBound();
    hurstcCost_ -= GetCostLwrBound();
  }

  if (bestCost_ == 0) {
    // If the heuristic schedule is optimal, we are done!
    schedUprBound_ = bestSchedLngth_;
    return true;
  } else if (IsSecondPass()) {
    // In the second pass, the upper bound is the length of the min-RP schedule
    // that was found in the first pass with stalls inserted.
    schedUprBound_ = schedule->GetCrntLngth();
    return false;
  } else {
    CmputSchedUprBound_();
    return false;
  }
}

__host__ __device__
void SchedRegion::UpdateScheduleCost(InstSchedule *schedule) {
  InstCount crntExecCost;
#ifdef __CUDA_ARCH__
  ((BBWithSpill *)this)->Dev_CmputNormCost_(schedule, CCM_STTC, crntExecCost, false);
#else
  CmputNormCost_(schedule, CCM_STTC, crntExecCost, false);
#endif
  // no need to return anything as all results can be found in the schedule
}

__host__ __device__
SPILL_COST_FUNCTION SchedRegion::GetSpillCostFunc() { return spillCostFunc_; }

void SchedRegion::HandlEnumrtrRslt_(FUNC_RESULT rslt, InstCount trgtLngth) {
  switch (rslt) {
  case RES_FAIL:
    //    #ifdef IS_DEBUG_ENUM_ITERS
    Logger::Info("No feasible solution of length %d was found.", trgtLngth);
    //    #endif
    break;
  case RES_SUCCESS:
#ifdef IS_DEBUG_ENUM_ITERS
    Logger::Info("Found a feasible solution of length %d.", trgtLngth);
#endif
    break;
  case RES_TIMEOUT:
    //    #ifdef IS_DEBUG_ENUM_ITERS
    Logger::Info("Enumeration timedout at length %d.", trgtLngth);
    //    #endif
    break;
  case RES_ERROR:
    Logger::Info("The processing of DAG \"%s\" was terminated with an error.",
                 dataDepGraph_->GetDagID(), rgnNum_);
    break;
  case RES_END:
    //    #ifdef IS_DEBUG_ENUM_ITERS
    Logger::Info("Enumeration ended at length %d.", trgtLngth);
    //    #endif
    break;
  }
}

void SchedRegion::RegAlloc_(InstSchedule *&bestSched, InstSchedule *&lstSched) {
  std::unique_ptr<LocalRegAlloc> u_regAllocBest = nullptr;
  std::unique_ptr<LocalRegAlloc> u_regAllocList = nullptr;

  if (SchedulerOptions::getInstance().GetString(
          "SIMULATE_REGISTER_ALLOCATION") == "HEURISTIC" ||
      SchedulerOptions::getInstance().GetString(
          "SIMULATE_REGISTER_ALLOCATION") == "BOTH" ||
      SchedulerOptions::getInstance().GetString(
          "SIMULATE_REGISTER_ALLOCATION") == "TAKE_SCHED_WITH_LEAST_SPILLS") {
    // Simulate register allocation using the heuristic schedule.
    u_regAllocList = std::unique_ptr<LocalRegAlloc>(
        new LocalRegAlloc(lstSched, dataDepGraph_));

    u_regAllocList->SetupForRegAlloc();
    u_regAllocList->AllocRegs();

    std::string id(dataDepGraph_->GetDagID());
    std::string heur_ident(" ***heuristic_schedule***");
    std::string ident(id + heur_ident);

    u_regAllocList->PrintSpillInfo(ident.c_str());
  }
  if (SchedulerOptions::getInstance().GetString(
          "SIMULATE_REGISTER_ALLOCATION") == "BEST" ||
      SchedulerOptions::getInstance().GetString(
          "SIMULATE_REGISTER_ALLOCATION") == "BOTH" ||
      SchedulerOptions::getInstance().GetString(
          "SIMULATE_REGISTER_ALLOCATION") == "TAKE_SCHED_WITH_LEAST_SPILLS") {
    // Simulate register allocation using the best schedule.
    u_regAllocBest = std::unique_ptr<LocalRegAlloc>(
        new LocalRegAlloc(bestSched, dataDepGraph_));

    u_regAllocBest->SetupForRegAlloc();
    u_regAllocBest->AllocRegs();

    u_regAllocBest->PrintSpillInfo(dataDepGraph_->GetDagID());
    totalSimSpills_ = u_regAllocBest->GetCost();
  }

  if (SchedulerOptions::getInstance().GetString(
          "SIMULATE_REGISTER_ALLOCATION") == "TAKE_SCHED_WITH_LEAST_SPILLS")
    if (u_regAllocList->GetCost() < u_regAllocBest->GetCost()) {
      bestSched = lstSched;
#ifdef IS_DEBUG
      Logger::Info(
          "Taking list schedule becuase of less spilling with simulated RA.");
#endif
    }
}

void SchedRegion::InitSecondPass() { isSecondPass_ = true; }

__global__
void InitCurand(curandState_t *dev_states, unsigned long seed) {
  curand_init(seed, GLOBALTID, 0, &dev_states[GLOBALTID]);
}

FUNC_RESULT SchedRegion::runACO(InstSchedule *ReturnSched,
                                InstSchedule *InitSched) {
  InitForSchdulng();
  FUNC_RESULT Rslt;
  if (DEV_ACO) {
    // Allocate and Copy data to device for parallel ACO
    size_t memSize;
    // Allocate arrays for parallel ACO execution
    Logger::Info("Allocating SchedInstruction Arrays for Parallel ACO");
    for (int i = 0; i < dataDepGraph_->GetInstCnt(); i++) {
      dataDepGraph_->GetInstByIndx(i)->AllocDevArraysForParallelACO(NUMTHREADS);
    }
    Logger::Info("Allocating Register Arrays for Parallel ACO");
    RegisterFile *regFiles = dataDepGraph_->getRegFiles();
    for (int i = 0; i < dataDepGraph_->GetRegTypeCnt(); i++) {
      for (int j = 0; j < regFiles[i].GetRegCnt(); j++)
        regFiles[i].GetReg(j)->AllocDevArrayForParallelACO(NUMTHREADS);
    }
    Logger::Info("Allocating BBWithSpill Arrays for Parallel ACO");
    ((BBWithSpill*)this)->AllocDevArraysForParallelACO(NUMTHREADS);
    // Copy DDG and its objects to device
    Logger::Info("Copying DDG and its Instruction to device");
    DataDepGraph *dev_DDG;
    memSize = sizeof(DataDepGraph);
    gpuErrchk(cudaMallocManaged(&dev_DDG, memSize));
    gpuErrchk(cudaMemcpy(dev_DDG, dataDepGraph_, memSize,
                         cudaMemcpyHostToDevice));
    dataDepGraph_->CopyPointersToDevice(dev_DDG);
    // Copy this(BBWithSpill) to device
    Logger::Info("Copying BBWithSpill to Device");
    BBWithSpill *dev_rgn;
    memSize = sizeof(BBWithSpill);
    // Allocate device mem
    gpuErrchk(cudaMallocManaged((void**)&dev_rgn, memSize));
    // Copy this to device
    gpuErrchk(cudaMemcpy(dev_rgn, this, memSize, cudaMemcpyHostToDevice));
    dev_rgn->machMdl_ = dev_machMdl_;
    CopyPointersToDevice(dev_rgn, NUMTHREADS);
    // Create and copy an array of DeviceVector<Choice>* for use during scheduling
    Logger::Info("Creating and Copying ready arrays to device");
    DeviceVector<Choice> **host_ready = new DeviceVector<Choice> *[NUMTHREADS];
    Choice *dev_elmnts;
    DeviceVector<Choice> *ready = 
            new DeviceVector<Choice>(dataDepGraph_->GetInstCnt());
    //memSize = sizeof(DeviceVector<Choice>);
    for (int i = 0; i < NUMTHREADS; i++) {
      memSize = sizeof(DeviceVector<Choice>);
      gpuErrchk(cudaMallocManaged(&host_ready[i], memSize));
      gpuErrchk(cudaMemcpy(host_ready[i], ready, memSize, 
                           cudaMemcpyHostToDevice));
      //copy ready->elmnts_ and link to dev_ready'
      memSize = sizeof(Choice) * dataDepGraph_->GetInstCnt();
      gpuErrchk(cudaMalloc(&dev_elmnts, memSize));
      gpuErrchk(cudaMemcpy(dev_elmnts, ready->elmnts_, memSize,
                           cudaMemcpyHostToDevice));
      host_ready[i]->elmnts_ = dev_elmnts;
    }
    delete ready;
    // copy array of device pointers to device
    DeviceVector<Choice> **dev_ready;
    memSize = sizeof(DeviceVector<Choice> *) * NUMTHREADS;
    gpuErrchk(cudaMalloc(&dev_ready, memSize));
    gpuErrchk(cudaMemcpy(dev_ready, host_ready, memSize, cudaMemcpyHostToDevice));
    // Allocate dev_states for curand RNG and run curand_init() to initialize
    Logger::Info("Initializing states for cuRand");
    curandState_t *dev_states;
    memSize = sizeof(curandState_t) * NUMTHREADS;
    gpuErrchk(cudaMalloc(&dev_states, memSize));
    InitCurand<<<NUMBLOCKS, NUMTHREADSPERBLOCK>>>(dev_states, 
                                                  unsigned(time(NULL)));
    //cudaDeviceSynchronize();
    Logger::Info("Creating ACOScheduler");
    ACOScheduler *AcoSchdulr = new ACOScheduler(
        dataDepGraph_, machMdl_, abslutSchedUprBound_, hurstcPrirts_, vrfySched_,
        (SchedRegion *)dev_rgn, dev_DDG, dev_ready, dev_machMdl_, dev_states);
    AcoSchdulr->setInitialSched(InitSched);
    // Alloc dev arrays for parallel ACO
    Logger::Info("Allocating ACOScheduler Arrays for Parallel ACO");
    AcoSchdulr->AllocDevArraysForParallelACO();
    // Copy ACOScheduler to device
    Logger::Info("Copying ACOScheduler to device");
    ACOScheduler *dev_AcoSchdulr;
    memSize = sizeof(ACOScheduler);
    gpuErrchk(cudaMallocManaged(&dev_AcoSchdulr, memSize));
    gpuErrchk(cudaMemcpy(dev_AcoSchdulr, AcoSchdulr, memSize,
                         cudaMemcpyHostToDevice));
    AcoSchdulr->CopyPointersToDevice(dev_AcoSchdulr);

    Rslt = AcoSchdulr->FindSchedule(ReturnSched, this, dev_AcoSchdulr);
    dev_AcoSchdulr->FreeDevicePointers();
    cudaFree(dev_AcoSchdulr);
    delete AcoSchdulr;

    for (int i = 0; i < NUMTHREADS; i++) {
      cudaFree(host_ready[i]->elmnts_);
      cudaFree(host_ready[i]);
    }
    cudaFree(dev_ready);
    delete[] host_ready;
    dev_rgn->FreeDevicePointers(NUMTHREADS);
    cudaFree(dev_rgn);
    dev_DDG->FreeDevicePointers(NUMTHREADS);
    cudaFree(dev_DDG);
    cudaFree(dev_states);
    // Ocasionally BBWithSpill deletes an empty pointer, which causes the next
    // kernel to report an invalid argument error after execution even
    // though the non issue error happens here. This call is to clear errors
    // from BBWithSpill deletion.
    cudaGetLastError();
  } else {
    ACOScheduler *AcoSchdulr = new ACOScheduler(
        dataDepGraph_, machMdl_, abslutSchedUprBound_, hurstcPrirts_, vrfySched_);
    AcoSchdulr->setInitialSched(InitSched);
    Rslt = AcoSchdulr->FindSchedule(ReturnSched, this);
  }
  return Rslt;
}
