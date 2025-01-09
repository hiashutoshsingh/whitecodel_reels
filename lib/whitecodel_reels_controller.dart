import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:get/get.dart';
import 'package:video_player/video_player.dart';

import 'video_controller_service.dart';

// Controller class for managing the reels in the app
class WhiteCodelReelsController extends GetxController
    with GetTickerProviderStateMixin, WidgetsBindingObserver {
  // Page controller for managing pages of videos
  PageController pageController = PageController(viewportFraction: 0.99999);

  // List of video player controllers
  RxList<VideoPlayerController> videoPlayerControllerList =
      <VideoPlayerController>[].obs;

  // Service for managing cached video controllers
  CachedVideoControllerService videoControllerService =
      CachedVideoControllerService(DefaultCacheManager());

  // Observable for loading state
  final loading = true.obs;

  // Observable for visibility state
  final visible = false.obs;

  // Animation controller for animating
  late AnimationController animationController;

  // Animation object
  late Animation animation;

  // Current page index
  int page = 1;

  // Limit for loading videos
  int limit = 10;

  // List of video URLs
  final List<String> reelsVideoList;

  // isCaching
  bool isCaching;

  // Observable list of video URLs
  RxList<String> videoList = <String>[].obs;

  // Limit for loading nearby videos
  int loadLimit = 3;

  // Flag for initialization
  bool init = false;

  // Timer for periodic tasks
  Timer? timer;

  // Index of the last video
  int? lastIndex;

  // Already listened list
  List<int> alreadyListened = [];

  // Caching video at index
  List<String> caching = [];

  // pageCount
  RxInt pageCount = 0.obs;

  final int startIndex;

  int? _currentStartIndex; // Tracks the currently active index

  // Constructor
  WhiteCodelReelsController({
    required this.reelsVideoList,
    required this.isCaching,
    this.startIndex = 0,
  });

  // Lifecycle method for handling app lifecycle state changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      // Pause all video players when the app is paused
      for (var i = 0; i < videoPlayerControllerList.length; i++) {
        videoPlayerControllerList[i].pause();
      }
    }
  }

  @override
  void onInit() {
    super.onInit();

    videoList.addAll(reelsVideoList);

    animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    animation = CurvedAnimation(
      parent: animationController,
      curve: Curves.easeIn,
    );

    // Populate videoPlayerControllerList before any other initialization
    addVideosController().then((_) {
      if (videoPlayerControllerList.isEmpty) {
        log('Error: videoPlayerControllerList is empty even after addVideosController.');
        return;
      }

      if (_currentStartIndex == null) {
        log('Forcing initialization for the first start at index 0.');
        _currentStartIndex = 0;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          initService(startIndex: 0); // Ensure it's deferred
        });
      } else {
        updateStartIndex(startIndex);
      }
    });

    timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (lastIndex != null) {
        initNearByVideos(lastIndex!);
      }
    });
  }

  // Lifecycle method called when the controller is closed
  @override
  void onClose() {
    timer?.cancel();
    animationController.dispose();
    // Pause and dispose all video players
    for (var i = 0; i < videoPlayerControllerList.length; i++) {
      videoPlayerControllerList[i].pause();
      videoPlayerControllerList[i].dispose();
    }
    super.onClose();
  }

  void updateStartIndex(int newStartIndex) {
    if (videoPlayerControllerList.isEmpty ||
        newStartIndex >= videoPlayerControllerList.length) {
      log('Error: videoPlayerControllerList is empty or index $newStartIndex is out of bounds.');
      return;
    }

    if (_currentStartIndex == newStartIndex) {
      log('Start index $newStartIndex is the same as the current index. Checking initialization.');
      if (!videoPlayerControllerList[newStartIndex].value.isInitialized) {
        log('Video at index $newStartIndex is not initialized. Forcing initialization.');
        initService(startIndex: newStartIndex); // Reinitialize if needed
      } else {
        videoPlayerControllerList[newStartIndex].play();
        log('Resuming playback for video at index $newStartIndex.');
      }
      return;
    }

    // Update the saved index and call initService
    _currentStartIndex = newStartIndex;
    initService(startIndex: newStartIndex);
  }

  Future<void> initService({int startIndex = 0}) async {
    log("<><><> initService called with startIndex: $startIndex");

    if (videoList.isEmpty) {
      log('Error: videoList is empty. Cannot initialize service.');
      return;
    }

    // Validate the start index
    if (startIndex < 0 || startIndex >= videoList.length) {
      log('Error: Invalid startIndex $startIndex. Must be in range 0..${videoList.length - 1}.');
      return;
    }

    // Ensure videoPlayerControllerList is populated
    if (videoPlayerControllerList.isEmpty) {
      log('Populating videoPlayerControllerList...');
      await addVideosController();
    }

    // Check again after population
    if (videoPlayerControllerList.isEmpty ||
        startIndex >= videoPlayerControllerList.length) {
      log('Error: videoPlayerControllerList is still empty or index $startIndex is out of bounds after population.');
      return;
    }

    _currentStartIndex = startIndex;

    // Defer updating the loading state
    SchedulerBinding.instance.addPostFrameCallback((_) {
      loading.value = true;
    });

    try {
      final controller = videoPlayerControllerList[startIndex];
      if (!controller.value.isInitialized) {
        log('Initializing video at index $startIndex.');
        cacheVideo(startIndex);
        await controller.initialize();
      }

      controller.play();
      log('Playback started for video at index $startIndex.');

      refreshView();
      await initNearByVideos(startIndex);

      if (!animationController.isAnimating) {
        animationController.reset();
        animationController.repeat();
      }

      Future.delayed(Duration.zero, () {
        pageController.jumpToPage(startIndex);
      });

      log('Page controller set to page $startIndex.');
    } catch (e, stackTrace) {
      log('Error during initService at index $startIndex: $e\n$stackTrace');
    } finally {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        loading.value = false;
      });
      log('initService completed for index $startIndex.');
    }
  }

  // Refresh loading state
  void refreshView() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      loading.value = true;
      loading.value = false;
    });
  }

  // Add video controllers
  Future<void> addVideosController() async {
    for (var i = 0; i < videoList.length; i++) {
      String videoFile = videoList[i];
      log('Adding video controller for video: $videoFile');
      final controller = await videoControllerService.getControllerForVideo(
          videoFile, isCaching);
      videoPlayerControllerList.add(controller);
      log('Video controller added for index $i.');
    }

    log('Total video controllers: ${videoPlayerControllerList.length}');
  }

  // Initialize nearby videos
  initNearByVideos(int index) async {
    if (init) {
      lastIndex = index;
      return;
    }
    lastIndex = null;
    init = true;
    if (loading.value) return;
    disposeNearByOldVideoControllers(index);
    await tryInit(index);
    try {
      var currentPage = index;
      var maxPage = currentPage + loadLimit;
      List<String> videoFiles = videoList;

      for (var i = currentPage; i < maxPage; i++) {
        if (videoFiles.asMap().containsKey(i)) {
          var controller = videoPlayerControllerList[i];
          if (!controller.value.isInitialized) {
            cacheVideo(i);
            await controller.initialize();
            increasePage(i + 1);
            refreshView();
            // listenEvents(i);
          }
        }
      }
      for (var i = index - 1; i > index - loadLimit; i--) {
        if (videoList.asMap().containsKey(i)) {
          var controller = videoPlayerControllerList[i];
          if (!controller.value.isInitialized) {
            if (!caching.contains(videoList[index])) {
              cacheVideo(index);
            }

            await controller.initialize();
            increasePage(i + 1);
            refreshView();
            // listenEvents(i);
          }
        }
      }

      refreshView();
      loading.value = false;
    } catch (e) {
      loading.value = false;
    } finally {
      loading.value = false;
    }
    init = false;
  }

  // Try initializing video at index
  tryInit(int index) async {
    var oldVideoPlayerController = videoPlayerControllerList[index];
    if (oldVideoPlayerController.value.isInitialized) {
      oldVideoPlayerController.play();
      refresh();
      return;
    }
    VideoPlayerController videoPlayerControllerTmp =
        await videoControllerService.getControllerForVideo(
            videoList[index], isCaching);
    videoPlayerControllerList[index] = videoPlayerControllerTmp;
    await oldVideoPlayerController.dispose();
    refreshView();
    if (!caching.contains(videoList[index])) {
      cacheVideo(index);
    }
    await videoPlayerControllerTmp
        .initialize()
        .catchError((e) {})
        .then((value) {
      videoPlayerControllerTmp.play();
      refresh();
    });
  }

  // Dispose nearby old video controllers
  disposeNearByOldVideoControllers(int index) async {
    loading.value = false;
    for (var i = index - loadLimit; i > 0; i--) {
      if (videoPlayerControllerList.asMap().containsKey(i)) {
        var oldVideoPlayerController = videoPlayerControllerList[i];
        VideoPlayerController videoPlayerControllerTmp =
            await videoControllerService.getControllerForVideo(
                videoList[i], isCaching);
        videoPlayerControllerList[i] = videoPlayerControllerTmp;
        alreadyListened.remove(i);
        await oldVideoPlayerController.dispose();
        refreshView();
      }
    }

    for (var i = index + loadLimit; i < videoPlayerControllerList.length; i++) {
      if (videoPlayerControllerList.asMap().containsKey(i)) {
        var oldVideoPlayerController = videoPlayerControllerList[i];
        VideoPlayerController videoPlayerControllerTmp =
            await videoControllerService.getControllerForVideo(
                videoList[i], isCaching);
        videoPlayerControllerList[i] = videoPlayerControllerTmp;
        alreadyListened.remove(i);
        await oldVideoPlayerController.dispose();
        refreshView();
      }
    }
  }

  // Listen to video events
  listenEvents(i, {bool force = false}) {
    if (alreadyListened.contains(i) && !force) return;
    alreadyListened.add(i);
    var videoPlayerController = videoPlayerControllerList[i];

    videoPlayerController.addListener(() {
      if (videoPlayerController.value.position ==
              videoPlayerController.value.duration &&
          videoPlayerController.value.duration != Duration.zero) {
        videoPlayerController.seekTo(Duration.zero);
        videoPlayerController.play();
      }
    });
  }

  // Listen to page events
  // pageEventsListen(path) {
  //   pageController.addListener(() {
  //     visible.value = false;
  //     Future.delayed(const Duration(milliseconds: 500), () {
  //       loading.value = false;
  //     });
  //     refreshView();
  //   });
  // }

  cacheVideo(int index) async {
    if (!isCaching) return;
    String url = videoList[index];
    if (caching.contains(url)) return;
    caching.add(url);
    final cacheManager = DefaultCacheManager();
    FileInfo? fileInfo = await cacheManager.getFileFromCache(url);
    if (fileInfo != null) {
      log('Video already cached: $index');
      return;
    }

    // log('Downloading video: $index');
    try {
      await cacheManager.downloadFile(url);
      // log('Downloaded video: $index');
    } catch (e) {
      // log('Error downloading video: $e');
      caching.remove(url);
    }
  }

  increasePage(v) {
    if (pageCount.value == videoList.length) return;
    if (pageCount.value >= v) return;
    pageCount.value = v;
  }
}
